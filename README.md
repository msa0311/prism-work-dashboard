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

4. **Wire each reporting agent to the dashboard.** This is the platform setup an
   agent must not guess at — run it once per reporting agent. You need the
   dashboard host `<dash-host>` = `<sandbox-slug>.<SANDBOX_INGRESS_HOST>` from
   step 3, plus the reporting agent's own `projectId` and `sandboxId`.

   **a. Mint a token** — `create_api_token { orgId, name, expiresInDays }`.
   Capture the returned `token`; it is shown only once.

   **b. Give the token access to the reporting agent's project — via a team.**
   This is the step that trips people up: the `auth: private` ingress authorizes
   the Bearer by checking whether the token can reach *its own* project, and a
   token gains project access **only** by being a member of a team that has that
   access — there is no direct token→project grant.
   - `list_teams { orgId }` and pick a team whose `projectAccess` includes the
     project (or `create_team` then `set_team_project_access { role: "MEMBER" }`).
   - `add_team_member { teamId, memberType: "AGENT", apiTokenId }`.

   **c. Store the token as an injecting credential** in the reporting agent's
   project — so the secret never has to live in the agent's writable
   `config.json`:

```json
{
  "tool": "create_credential",
  "arguments": {
    "projectId": "<projectId>",
    "name": "work-dashboard-otlp",
    "value": "<token from step a>",
    "injections": [
      {
        "domain": "<dash-host>",
        "headerName": "Authorization",
        "headerFormat": "Bearer {value}",
        "rules": [
          { "path": "/v1/logs", "method": "POST" },
          { "path": "/v1/**", "method": "POST" }
        ]
      }
    ]
  }
}
```

   **d. Create the egress policy** — it both allows the ingest host and pulls in
   the credential so the proxy injects the token:

```json
{
  "tool": "create_policy",
  "arguments": {
    "projectId": "<projectId>",
    "name": "work-dashboard-otlp-egress",
    "allowedDomains": [
      {
        "pattern": "<dash-host>",
        "verdict": "allow",
        "transport": "direct",
        "rules": [
          { "path": "/v1/logs", "method": "POST" },
          { "path": "/v1/**", "method": "POST" }
        ]
      }
    ],
    "credentials": [{ "credentialName": "work-dashboard-otlp" }]
  }
}
```

   **e. Attach the policy to the reporting agent's sandbox** (metadata only — no
   restart): read the current `policyIds` with `get_sandbox`, then
   `update_sandbox { policies: [...existing, <newPolicyId>] }`. Attach it to the
   **reporting agent's** sandbox, not the dashboard's.

   **f. Point the skill at the endpoint — with no auth header.** The
   [prism-work-telemetry](https://github.com/msa0311/prism-work-telemetry)
   skill's `/data/work-telemetry/config.json` gets just
   `{"endpoint":"https://<dash-host>"}`. The egress proxy injects `Authorization`
   for you; setting it in `config.json` too sends the header twice. (Prefer this
   over `auth: public` + `OTLP_AUTH_TOKEN`, which puts a shared secret in the
   sandbox env and in every sender's headers.)

   **Verify:** emit one work record (or a single `POST /v1/logs` from the
   reporting sandbox) and confirm a 2xx plus a new row on the **Agent Work**
   dashboard.

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
