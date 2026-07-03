---
name: observability-stack
description: >-
  Conventions AND review checks for the local OTel Collector → Prometheus →
  Loki → Grafana observability stack: telemetry pipeline wiring, container
  networking for telemetry (service names, ports, scrape configs), and the
  overnight runner's OTEL_EXPORTER_OTLP_* env plumbing. Use whenever building
  or reviewing the collector config, a Prometheus/Loki/Grafana service, a
  scrape config, or anything that exports OpenTelemetry metrics/logs — even if
  the task just says "wire up telemetry" or "add a dashboard". Carries the
  silent-drop and credential footguns learned the hard way; check them before
  shipping.
---

# Observability stack (OTel Collector → Prometheus / Loki → Grafana)

## The pipeline

`.devcontainer/otel-collector-config.yaml` is the source of truth:

- **Receiver**: `otlp` on `0.0.0.0:4317` (gRPC) and `0.0.0.0:4318` (HTTP) —
  this is what the sandboxed Claude Code process (and the overnight runner)
  exports to.
- **Processor**: `batch` on both pipelines.
- **Exporters**: `prometheus` (scrape endpoint `0.0.0.0:9464`) for metrics,
  `otlphttp/loki` (`http://loki:3100/otlp`) for logs.
- **Pipelines**: `metrics: [otlp] → [batch] → [prometheus]`,
  `logs: [otlp] → [batch] → [otlphttp/loki]`.

Prometheus (`.devcontainer/prometheus.yml`) scrapes the collector, not the
sandbox directly:

```yaml
scrape_configs:
  - job_name: otel-collector
    static_configs:
      - targets: ["otel-collector:9464"]
```

`scrape_interval: 10s` is deliberately matched to the runner's
`OTEL_METRIC_EXPORT_INTERVAL` (see below) — if you change one, change the
other, or you'll get a stale/aliased view of short-lived metrics.

Grafana (`.devcontainer/grafana/provisioning/datasources/datasources.yml`)
provisions both backends by compose service name — `http://prometheus:9090`
(default datasource) and `http://loki:3100` — so dashboards work out of the
box with no manual datasource setup.

## Container networking for telemetry

Everything resolves by **compose service name**, not `localhost`, because
the collector, Prometheus, Loki, and Grafana are sibling containers on the
compose network:

- Sandbox → collector: `OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4317`
  (gRPC), set as a compose `environment:` entry so it applies to every shell
  in the container, interactive or headless.
- Collector → Loki: `http://loki:3100/otlp` (OTLP log ingest; Loki 3.x
  accepts this natively at `/otlp` with its default config).
- Grafana → Prometheus/Loki: by service name, as above.
- `depends_on` sequences bring-up order (sandbox → otel-collector → loki;
  grafana → prometheus + loki) but does **not** wait for the dependency to be
  ready to serve — only that its container has started. A collector that
  hasn't finished initializing when the first metrics land will drop them;
  this is usually harmless for a long-lived dev session but matters for
  short-lived smoke tests right after `docker compose up`.
- **Host ports** are opened only where a human needs to look:
  Prometheus `9090` ("optional: raw metric spelunking from the host
  browser") and Grafana `3000` ("the morning dashboard:
  http://localhost:3000"). The otel-collector has **no host ports** by
  default — the sandbox reaches it over the compose network, not the host —
  with `4317`/`4318` commented out in `docker-compose.yml` for the case
  where a host-side (non-container) `claude` session also needs to export
  here.
- Every stack image (`otel/opentelemetry-collector-contrib:latest`,
  `prom/prometheus:latest`, `grafana/loki:latest`, `grafana/grafana:latest`)
  is intentionally on `:latest` for now, flagged in-line as "pin a version
  once happy" — treat that comment as a standing TODO, not an oversight, when
  reviewing.

## The overnight runner's OTel wiring

`tools/run-overnight.sh` is the other half of this — it's what actually
populates the pipeline during unattended runs. When `OTEL_ENABLED=1`
(default), it exports:

- `CLAUDE_CODE_ENABLE_TELEMETRY=1`
- `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` — default `otlp`.
- `OTEL_EXPORTER_OTLP_PROTOCOL` — default `grpc`.
- `OTEL_EXPORTER_OTLP_ENDPOINT` — default `http://localhost:4317`. This
  localhost default is for the case where the script runs *inside* the
  devcontainer's own shell; the compose `environment:` block overrides it to
  `http://otel-collector:4317` for the sandbox service itself. Pointing at a
  cloud backend (Grafana Cloud, SigNoz, …) means overriding this plus
  `OTEL_EXPORTER_OTLP_HEADERS` for auth.
- `OTEL_METRIC_EXPORT_INTERVAL` / `OTEL_LOGS_EXPORT_INTERVAL` — tightened to
  10s/5s from the SDK's 60s default so short iterations don't lose their tail
  before the process exits.

After the work loop, `ANALYZE_TELEMETRY=1` (default) runs `/analyze-telemetry`
in a fresh headless pass, passing through `PROM_URL` (default
`http://prometheus:9090`) and `LOKI_URL` (default `http://loki:3100`) for the
aggregate queries it uses to correlate telemetry against per-iteration
session logs and file `[token-efficiency]` beads.

## Footguns (learned the hard way)

- **Exports drop silently if nothing is listening at the endpoint.** There is
  no error, no retry-and-fail-loud — the SDK just swallows it. If a metric
  never shows up in Grafana, don't assume the pipeline is broken; first rule
  out "nobody's home" by setting `OTEL_METRICS_EXPORTER=console` and checking
  stdout, *then* debug the collector/exporter config.
- **Credentials belong in the collector, not the sandbox.** The whole reason
  the pipeline routes through `otel-collector` instead of exporting straight
  to a cloud backend from inside the (deny-by-default, egress-restricted)
  sandbox is so that backend auth (API keys, tokens) lives in the collector's
  config/exporter, outside the sandboxed container. Don't shortcut this by
  pushing `OTEL_EXPORTER_OTLP_HEADERS` with real credentials into the sandbox
  environment.
- **Keep content structural by default.** Telemetry here is tokens, cost,
  tool calls — not prompt text — unless a user has explicitly opted in (e.g.
  `OTEL_LOG_USER_PROMPTS`). Don't add a config change that widens this by
  default.
- **Loki OTLP ingest 400s** usually mean `allow_structured_metadata` in the
  Loki config, not a malformed collector export — check that before
  reworking the exporter.
- **Grafana anonymous-admin auth is a local-only convenience**
  (`GF_AUTH_ANONYMOUS_ENABLED` / `..._ORG_ROLE: Admin` /
  `..._DISABLE_LOGIN_FORM`) that trades security for zero-friction morning
  dashboards. Never expose Grafana's `3000` port beyond localhost with this
  configuration in place.
- **The scrape interval and the export interval are a matched pair.**
  Prometheus's `scrape_interval: 10s` assumes the runner's
  `OTEL_METRIC_EXPORT_INTERVAL` stays at 10s; drifting one without the other
  produces misleading gaps or duplication in dashboards built against the
  10s cadence.

## Review checklist

- New metric/log path added without checking it actually reaches Grafana
  (i.e. no "nothing's listening" smoke test via `OTEL_METRICS_EXPORTER=console`).
- Backend credentials (API keys, bearer tokens) placed in the sandboxed
  container's environment instead of the collector's exporter config.
- A change that starts logging prompt text or other non-structural content
  by default, without an explicit opt-in flag.
- Prometheus `scrape_interval` and the runner's `OTEL_METRIC_EXPORT_INTERVAL`
  changed independently, leaving them mismatched.
- A telemetry service (Prometheus, Grafana, or the collector's debug port)
  exposed on a host port beyond localhost, especially with Grafana's
  anonymous-admin auth still enabled.
- Collector, Prometheus, Loki, or Grafana pinned to a real version without
  updating the "pin a version once happy" TODO, or left unpinned past the
  bring-up stage without a tracked follow-up.
- A new service added to the pipeline without wiring it into
  `depends_on` and, if it serves data, the Grafana datasource provisioning.
