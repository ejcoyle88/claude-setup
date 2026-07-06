#!/usr/bin/env node
// Rebuilds tools/ollama-mcp's dist/ output into a scratch directory from the
// currently checked-out src/ (via the same `tsc` invocation `npm run build`
// uses), then sha256-diffs it against the dist/ that .mcp.json actually
// wires up (`node tools/ollama-mcp/dist/index.js`). dist/ is git-ignored --
// nothing about its bytes is reviewed via `git diff` -- so this is the
// provenance check for "does what's about to auto-launch actually match the
// reviewed src/ in this checkout", not a build step itself. Exits non-zero
// (fail loud) on any missing/extra/mismatched file, or if dist/ is absent
// entirely. Dependency-free: only Node built-ins, no new devDependency.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, readdirSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const pkgRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const distDir = join(pkgRoot, "dist");
const tscBin = join(pkgRoot, "node_modules", ".bin", "tsc");

function listFiles(root) {
  const out = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile()) {
        out.push(full);
      } else if (entry.isSymbolicLink()) {
        fail(`refusing to verify: ${full} is a symlink (not supported by verify-dist)`);
      } else {
        fail(`refusing to verify: ${full} is neither a file nor a directory`);
      }
    }
  };
  walk(root);
  return out;
}

function hashTree(root) {
  const hashes = new Map();
  for (const file of listFiles(root)) {
    const rel = relative(root, file);
    const digest = createHash("sha256").update(readFileSync(file)).digest("hex");
    hashes.set(rel, digest);
  }
  return hashes;
}

// Thrown by fail() to unwind out of the try/finally below without skipping
// the scratchDir cleanup: process.exit() does not run pending `finally`
// blocks, so failures must propagate as a normal exception instead.
class VerifyFailure extends Error {}

function fail(message) {
  throw new VerifyFailure(message);
}

let exitCode = 0;
try {
  let distStat;
  try {
    distStat = statSync(distDir);
  } catch {
    fail(
      "dist/ does not exist. Run `npm install && npm run build` from the " +
        "currently checked-out src/ before trusting this server via .mcp.json.",
    );
  }
  if (!distStat.isDirectory()) {
    fail(`${distDir} exists but is not a directory.`);
  }

  const scratchDir = mkdtempSync(join(tmpdir(), "ollama-mcp-verify-"));
  try {
    const build = spawnSync(tscBin, ["--outDir", scratchDir], {
      cwd: pkgRoot,
      stdio: "inherit",
    });
    if (build.error) {
      fail(`could not run tsc (${tscBin}): ${build.error.message}`);
    }
    if (build.status !== 0) {
      fail("fresh `tsc` build from src/ failed -- see compiler output above.");
    }

    const fresh = hashTree(scratchDir);
    const existing = hashTree(distDir);

    const freshFiles = new Set(fresh.keys());
    const existingFiles = new Set(existing.keys());

    const missingFromDist = [...freshFiles].filter((f) => !existingFiles.has(f));
    const extraInDist = [...existingFiles].filter((f) => !freshFiles.has(f));
    const mismatched = [...freshFiles]
      .filter((f) => existingFiles.has(f) && fresh.get(f) !== existing.get(f))
      .sort();

    if (missingFromDist.length === 0 && extraInDist.length === 0 && mismatched.length === 0) {
      console.log(
        `verify-dist: OK -- dist/ (${existingFiles.size} file(s)) matches a fresh build of src/.`,
      );
    } else {
      console.error(
        "verify-dist: dist/ does NOT match a fresh build of the currently checked-out src/.",
      );
      console.error(
        "This means the committed .mcp.json would auto-launch bytes that were never reviewed " +
          "as part of src/ (stale build, local tampering, or a build-time dependency that " +
          "produced different output than expected).",
      );
      if (missingFromDist.length > 0) {
        console.error(`  Files a fresh build produces but dist/ is missing: ${missingFromDist.sort().join(", ")}`);
      }
      if (extraInDist.length > 0) {
        console.error(`  Files present in dist/ but not produced by a fresh build: ${extraInDist.sort().join(", ")}`);
      }
      if (mismatched.length > 0) {
        console.error(`  Files present in both but with different content: ${mismatched.join(", ")}`);
      }
      console.error("Run `npm run build` to regenerate dist/ from the reviewed src/, then re-run `npm run verify`.");
      exitCode = 1;
    }
  } finally {
    rmSync(scratchDir, { recursive: true, force: true });
  }
} catch (err) {
  if (err instanceof VerifyFailure) {
    console.error(`verify-dist: ${err.message}`);
    exitCode = 1;
  } else {
    throw err;
  }
}

process.exit(exitCode);
