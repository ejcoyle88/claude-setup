#!/usr/bin/env python3
"""
Detect the effective C# language-version *floor* across a repository.

For each .csproj it computes the safely-usable C# version:
  - start from the target framework's default C# version (net8.0 -> 12, etc.);
    for multi-targeting, use the *lowest* target framework
  - if <LangVersion> pins a lower number, use that (a deliberate cap)
  - if <LangVersion> pins a higher number than the TFM allows, that's
    unsupported (C# N only runs on its matching runtime) — the safe ceiling
    stays at the TFM default, and we warn
  - a non-numeric <LangVersion> (latest/latestMajor/preview/default) means
    "newest", but newest-beyond-the-TFM needs a newer runtime, so the safe
    ceiling is still the TFM default (noted)
Values inherited from a Directory.Build.props are used when a project omits its
own. The reported floor is the minimum ceiling across all projects — the version
that unconditional (non-`#if`) code must compile against everywhere.

Usage:  python3 detect-langversion.py [repo-root]   (default: .)

This is a fast, build-free heuristic. For an exact value on a tricky project,
cross-check with:  dotnet msbuild <proj> -getProperty:LangVersion
(optionally with -p:TargetFramework=<tfm> for a multi-target project).
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

# Target framework -> default C# version (when <LangVersion> is not pinned).
TFM_DEFAULT = {
    "net10.0": 14.0, "net9.0": 13.0, "net8.0": 12.0, "net7.0": 11.0,
    "net6.0": 10.0, "net5.0": 9.0,
    "netcoreapp3.1": 8.0, "netcoreapp3.0": 8.0,
    "netstandard2.1": 8.0, "netstandard2.0": 7.3,
}


def tfm_to_csharp(tfm):
    tfm = tfm.strip().lower()
    if tfm in TFM_DEFAULT:
        return TFM_DEFAULT[tfm]
    if tfm.startswith("net4") or tfm.startswith("net3") or tfm.startswith("net2"):
        return 7.3  # .NET Framework
    if tfm.startswith("netcoreapp2"):
        return 7.3
    return None  # unknown -> caller warns


def parse_version(text):
    """Numeric LangVersion -> float; latest/preview/default/etc -> None."""
    if not text:
        return None
    t = text.strip().lower()
    if t in ("latest", "latestmajor", "preview", "default"):
        return None
    m = re.match(r"^(\d+)(?:\.(\d+))?$", t)
    if m:
        return float(f"{m.group(1)}.{m.group(2) or '0'}")
    return None


def local(tag):
    return tag.rsplit("}", 1)[-1]  # strip xmlns


def read_props(path):
    """Return (langversion_text, [tfms]) from a csproj/props file (best effort)."""
    lang, tfms = None, []
    try:
        root = ET.parse(path).getroot()
    except Exception:
        return lang, tfms
    for el in root.iter():
        tag = local(el.tag)
        val = (el.text or "").strip()
        if tag == "LangVersion" and val:
            lang = val
        elif tag == "TargetFramework" and val:
            tfms.extend(v for v in val.split(";") if v.strip())
        elif tag == "TargetFrameworks" and val:
            tfms.extend(v for v in val.split(";") if v.strip())
    return lang, tfms


def nearest_props_default(csproj_dir, props_index):
    """Walk up from a project dir to find inherited LangVersion/TFMs."""
    lang, tfms = None, []
    d = os.path.abspath(csproj_dir)
    while True:
        if d in props_index:
            p_lang, p_tfms = props_index[d]
            lang = lang or p_lang
            tfms = tfms or p_tfms
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return lang, tfms


CSHARP_LABEL = {14.0: "C# 14", 13.0: "C# 13", 12.0: "C# 12", 11.0: "C# 11",
                10.0: "C# 10", 9.0: "C# 9", 8.0: "C# 8", 7.3: "C# 7.3"}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    csprojs, props_index = [], {}
    for dirpath, _dirs, files in os.walk(root):
        if any(seg in dirpath for seg in (os.sep + "bin", os.sep + "obj",
                                          os.sep + "node_modules", os.sep + ".git")):
            continue
        for f in files:
            full = os.path.join(dirpath, f)
            if f.endswith(".csproj"):
                csprojs.append(full)
            elif f == "Directory.Build.props":
                props_index[os.path.abspath(dirpath)] = read_props(full)

    if not csprojs:
        print("No .csproj files found under", os.path.abspath(root))
        sys.exit(0)

    results, warnings, floor = [], [], None
    for proj in sorted(csprojs):
        lang, tfms = read_props(proj)
        inh_lang, inh_tfms = nearest_props_default(os.path.dirname(proj), props_index)
        lang = lang or inh_lang
        tfms = tfms or inh_tfms
        if not tfms:
            warnings.append(f"{proj}: no target framework found; skipped")
            continue

        csharp_by_tfm = []
        for tfm in tfms:
            c = tfm_to_csharp(tfm)
            if c is None:
                warnings.append(f"{proj}: unknown TFM '{tfm}', assuming C# 7.3")
                c = 7.3
            csharp_by_tfm.append(c)
        tfm_ceiling = min(csharp_by_tfm)  # lowest TFM wins for shared code

        pinned = parse_version(lang)
        if pinned is None:
            ceiling = tfm_ceiling
            if lang:  # latest/preview/default
                warnings.append(f"{proj}: LangVersion='{lang}' (newest); safe "
                                f"ceiling held at {CSHARP_LABEL.get(tfm_ceiling, tfm_ceiling)} "
                                f"(TFM runtime limit)")
        elif pinned > tfm_ceiling:
            ceiling = tfm_ceiling
            warnings.append(f"{proj}: LangVersion {pinned:g} pinned ABOVE the TFM "
                            f"default {CSHARP_LABEL.get(tfm_ceiling, tfm_ceiling)} — "
                            f"unsupported; using the TFM default as the safe ceiling")
        else:
            ceiling = pinned  # deliberate lower cap

        results.append((proj, ";".join(tfms), lang or "(default)", ceiling))
        floor = ceiling if floor is None else min(floor, ceiling)

    print("=" * 60)
    print(f"C# FLOOR: {CSHARP_LABEL.get(floor, floor)}")
    print("Unconditional (non-#if) code must compile at this version.")
    print("=" * 60)
    for proj, tfms, lang, ceiling in results:
        rel = os.path.relpath(proj, root)
        print(f"  {CSHARP_LABEL.get(ceiling, ceiling):7}  {rel}  "
              f"[TFM={tfms}, LangVersion={lang}]")
    if warnings:
        print("\nNotes:")
        for w in warnings:
            print("  - " + w)


if __name__ == "__main__":
    main()