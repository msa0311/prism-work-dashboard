# prism-work-dashboard

The central dashboard for **agent work telemetry**: one container image running
**OTel Collector → ClickHouse → Grafana**, fronted by nginx on a **single HTTP
port** — sized to run as a [Lens agents](https://github.com/lensapp) **sandbox**
(one container, one exposed port, one persistent volume) or anywhere Docker runs.

It visualizes the records emitted by the
**[prism-work-telemetry](https://github.com/msa0311/prism-work-telemetry)**
Agent Skill (`work.schema=1`): work items over time by outcome, severity and
root-cause breakdowns, time-to-outcome percentiles, estimated human minutes
saved, 24 h recurrence rate, and a per-agent fleet table.

```
agents ──POST /v1/logs (OTLP/HTTP)──►┌───────────── :8080 (nginx) ─────────────┐
                                     │  /v1/*  → otel-collector :4318          │
humans ──GET / (browser)────────────►│  /*     → grafana :3000                 │
                                     │  collector → clickhouse (localhost)     │
                                     │  clickhouse data → /var/lib/clickhouse  │
                                     └──────────────────────────────────────────┘
```

Everything shares one port on purpose: the Lens sandbox ingress exposes exactly
one HTTP/1.1 port, so OTLP ingest and the Grafana UI are path-muxed by nginx.
(OTLP gRPC and the ClickHouse native protocol are deliberately not exposed.)

## Quickstart (local)

```bash
docker compose up --build
# Grafana:     http://localhost:8080          (anonymous Viewer enabled by default)
# OTLP ingest: http://localhost:8080/v1/logs
```

Send a test record and watch the **Agent Work** dashboard populate:

```bash
curl -s http://localhost:8080/v1/logs -H 'content-type: application/json' -d '{
  "resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"prism-work-telemetry"}}]},
  "scopeLogs":[{"scope":{"name":"prism-work-telemetry","version":"1"},"logRecords":[{
    "timeUnixNano":"'"$(date +%s)"'000000000","severityNumber":9,"eventName":"work.record",
    "body":{"stringValue":"work.record"},
    "attributes":[{"key":"work.schema","value":{"stringValue":"1"}},
      {"key":"work.type","value":{"stringValue":"k8s.triage"}},
      {"key":"work.outcome","value":{"stringValue":"diagnosed"}},
      {"key":"work.trigger","value":{"stringValue":"webhook"}},
      {"key":"agent.name","value":{"stringValue":"Test Agent"}}]}]}]}]}'
```

## Install to Lens Agents (instructions for an agent)

The steps below are written so an agent with the **Lens Agents MCP server** can
execute them. Human operators can do the same through the API/UI.

1. **Pick the project.** Call `list_projects` and confirm the target
   `projectId` with the user.

2. **Create the sandbox** (requires org admin):

```json
{
  "tool": "create_sandbox",
  "arguments": {
    "projectId": "<projectId>",
    "name": "work-dashboard",
    "image": "ghcr.io/msa0311/prism-work-dashboard:latest",
    "command": "/entrypoint.sh",
    "volumes": [{ "mountPath": "/var/lib/clickhouse" }],
    "exposedPorts": [{ "name": "web", "port": 8080, "auth": "private" }],
    "healthCheck": {
      "type": "http",
      "http": { "path": "/api/health", "port": 8080 },
      "initialDelaySeconds": 60
    }
  }
}
```

3. **Wait for it to start.** Poll `get_sandbox` until the state is started,
   then report the ingress URL — `https://<sandbox-slug>.<SANDBOX_INGRESS_HOST>`.
   Opening it in a browser shows the Grafana **Agent Work** dashboard (with
   `auth: private`, the platform sends browsers through the OIDC login first).

4. **Tell the user what remains on their side** (the platform pieces an agent
   must not guess at):
   - **Egress policy**: every agent that should report work needs the dashboard
     hostname allowed in its sandbox egress policy.
   - **Auth**: with `auth: private`, senders need a **Nexus API token** as
     `Authorization: Bearer <token>` (the platform's edge authenticates and
     forwards). With `auth: public`, set the `OTLP_AUTH_TOKEN` env on the
     sandbox instead and senders add `X-Otlp-Token: <token>`.
   - **Point the agents at it**: on each agent, the
     [prism-work-telemetry](https://github.com/msa0311/prism-work-telemetry)
     skill's `/data/work-telemetry/config.json` gets
     `{"endpoint":"https://<slug>.<host>","headers":{"Authorization":"Bearer <token>"}}`.

### Sandbox sizing caveats

Sandbox CPU/memory are platform-global (default ~500m/2Gi) — fine for demo and
small-fleet volumes, tight for heavy ClickHouse load. The single persistent
volume holds ClickHouse data (`/var/lib/clickhouse`); Grafana state is
ephemeral by design — dashboards are provisioned from the image, but manually
created dashboards/users are lost on restart. For production scale, run this
stack as a real platform service instead of a sandbox.

## Configuration (env)

| Variable | Default | Purpose |
|---|---|---|
| `GF_AUTH_ANONYMOUS_ENABLED` | `true` | Anonymous **Viewer** access to Grafana (the sandbox `private` port already gates who reaches it). Set `false` to require Grafana login. |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` | Grafana admin password (any `GF_*` env is passed through to Grafana). |
| `OTLP_AUTH_TOKEN` | unset | When set, `/v1/*` ingest requires header `X-Otlp-Token: <token>`. Use with a `public` port. |

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` / `entrypoint.sh` | All-in-one image; entrypoint supervises clickhouse, otelcol-contrib, grafana, nginx (no init system in sandbox pods). |
| `nginx.conf.template` | The single-port mux: `/v1/*` → collector, rest → Grafana. |
| `otel-collector/config.yaml` | OTLP/HTTP receiver → batch → ClickHouse exporter (`otel.otel_logs`, auto-created schema). |
| `grafana/dashboards/agent-work.json` | The Agent Work dashboard (consumes `work.schema=1` — see the skill repo's `references/schema.md`, the contract between the two repos). |
| `grafana/provisioning/` | ClickHouse datasource + dashboard provider. |
| `.github/workflows/publish.yml` | Builds and pushes `ghcr.io/<owner>/prism-work-dashboard` (amd64+arm64) on `main` and `v*` tags. |

## License

Apache-2.0
