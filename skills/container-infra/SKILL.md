---
name: container-infra
description: >-
  Conventions AND review checks for containerized dev environments: Dockerfiles,
  docker-compose, devcontainers, and the egress-firewall sandbox model. Use
  whenever building or reviewing an image, a compose service, a devcontainer
  config, a mount, a capability/port, or a firewall rule — even if the task just
  says "add a service" or "install X in the container". Carries the mount and
  build-vs-runtime footguns learned the hard way; check them before shipping.
---

# Container & devcontainer infrastructure

## Images (Dockerfile)

- **Pin** the base image and any release binaries/tool versions; `latest` is for
  bring-up only. Reproducibility beats convenience for a sandbox agents run in.
- **Least privilege**: create and switch to a non-root user; grant capabilities
  narrowly; scope sudoers to the single command that needs it. No secrets baked
  into layers, ever (they persist in history even if later removed).
- **Layer hygiene**: cheap/stable layers first for cache reuse; one
  `apt-get update && install && clean && rm -rf /var/lib/apt/lists/*` per RUN;
  `--no-install-recommends`.
- **Install at BUILD time** what the runtime firewall would otherwise block. The
  build has open network; a locked-down runtime does not. A tool fetched at
  build time needs no runtime egress.

## Compose & devcontainers

- **Compose-mode devcontainers drop `runArgs` / `mounts` / `containerEnv`** —
  those move to the compose service (`cap_add` / `volumes` / `environment`). Add
  `shutdownAction: stopCompose` so sidecars stop with the container.
- **`devcontainer.json` is JSONC** — comments and trailing commas are legal;
  never validate it as strict JSON.
- **Named volume vs bind**: a named volume starts EMPTY (no host content); a bind
  reflects the host. Choose deliberately — an empty `~/.claude` volume contains
  none of your config; a bind of the repo makes edits live.
- **Pin the subnet** when other logic derives from the network. The firewall
  derives its allowed host range from the default gateway's /24; a pinned
  `x.y.z.0/24` makes that coverage provable instead of luck.

## Mount footguns (learned the hard way)

- **A single-file bind mount whose host path is missing fabricates an empty
  DIRECTORY** and mounts it over the target — silent "no datasources" / "config
  is a folder" failures. Fixes, in order of robustness:
  1. Compose top-level **`configs:`** (content injected client-side; the daemon
     never resolves the host path — immune to snap/Desktop-VM path mapping).
  2. Long-syntax bind with **`create_host_path: false`** (missing file → clear
     error at `up` instead of fabrication).
     Directory binds don't hit the file-vs-dir mismatch, but still benefit from
     `create_host_path: false`.
- **A stale container keeps its mount config** — mounts are frozen at container
  _creation_. After fixing a mount, `docker compose up -d --force-recreate`.
- **Snap Docker / Docker Desktop-for-Linux** run the daemon confined or in a VM;
  bind paths that don't resolve in the daemon's view get fabricated. `configs:`
  sidesteps this class entirely.

## Firewall / egress model

- Default-DROP egress with an ipset allowlist. Adding a dependency may mean
  adding an allowed domain — but the script resolves domains to IPs ONCE at
  start, so load-balanced endpoints (cloud gateways) go stale mid-run. Prefer
  build-time fetch, or route through a forwarding proxy, over widening runtime
  egress to a rotating target.
- The firewall runs at `postStartCommand`, AFTER the image build — so build-time
  installs never touch it.

## Review checklist

- Container runs as root, or broad `cap_add` / `--privileged` without cause.
- Secret baked into an image layer or committed; port exposed beyond localhost
  without reason.
- Unpinned base image / release binary in something meant to be reproducible.
- Single-file bind mount without `configs:` or `create_host_path: false` (silent
  fabrication risk).
- Compose-mode devcontainer still using `runArgs`/`mounts`/`containerEnv`.
- `devcontainer.json` validated/authored as strict JSON.
- Firewall widened to a DNS-pinned rotating endpoint; or a runtime fetch that
  should have been a build-time install.
- Named volume used where a bind (or vice versa) was intended.
