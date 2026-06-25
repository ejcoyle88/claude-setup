---
name: rust-dependencies
description: >-
  Dependency conventions AND review checks for Rust/Cargo: choosing and pinning
  crates, feature flags and default-features, MSRV, `Cargo.lock` policy, and
  supply-chain/license checks with `cargo audit` and `cargo deny`. Use whenever
  adding, updating, replacing, or reviewing a crate dependency — or judging
  whether one is warranted, healthy, acceptably licensed, or safe — even if the
  task just says "add a crate for X".
---

# Dependencies (Cargo)

- Is a new crate actually warranted, or do `std` / an existing dependency already
  cover it? Prefer fewer, well-maintained crates over a deep dependency tree.
- **Feature flags**: pull in only the features you use; set
  `default-features = false` and opt in deliberately for heavy crates. Expose your
  own crate's optional functionality behind features too.
- **MSRV**: respect the project's minimum supported Rust version; don't silently
  raise it by adopting a crate or edition feature that bumps it.
- **`Cargo.lock`**: commit it for binaries (reproducible builds); libraries don't
  commit it. Pin exact versions only when you have a specific reason.
- **Supply chain & licensing**: run `cargo audit` (RUSTSEC advisories) and
  `cargo deny check` (licenses, bans, duplicate versions, sources). Keep an
  allowed-license policy in `deny.toml`.
- Vet new crates for maintenance health (recent releases, issue backlog) and
  download/reputation signals before adding.

## Review checklist

- New dependency that isn't warranted, or duplicates something already present.
- Heavy crate pulled in with `default-features` on where a slim feature set would do.
- A crate or feature that silently raises MSRV.
- Known advisory (`cargo audit`) or a license outside policy (`cargo deny`) —
  severity for advisories is the security reviewer's call.
- Binary crate without a committed `Cargo.lock`.
- Unmaintained or low-trust crate added to a core path.