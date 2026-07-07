#!/bin/bash
# Starts and supervises all four processes. The Lens agents sandbox runs pods
# with restartPolicy: Never and no in-pod init system, so each process gets a
# dumb restart loop here instead.
set -u

log() { echo "[prism-work-dashboard] $*"; }

# --- nginx config: single-port mux (8080) --------------------------------
# Optional shared-secret check for OTLP ingest: set OTLP_AUTH_TOKEN and senders
# must send "X-Otlp-Token: <token>". (Use this when the port is public; behind
# a Lens sandbox `auth: private` port the platform already authenticates and
# strips its own Authorization header.)
if [ -n "${OTLP_AUTH_TOKEN:-}" ]; then
  export OTLP_AUTH_CHECK="if (\$http_x_otlp_token != \"${OTLP_AUTH_TOKEN}\") { return 401; }"
else
  export OTLP_AUTH_CHECK=""
fi
envsubst '${OTLP_AUTH_CHECK}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# --- permissions (PVCs usually mount root-owned) --------------------------
mkdir -p /var/lib/clickhouse /var/log/clickhouse-server
chown -R clickhouse:clickhouse /var/lib/clickhouse /var/log/clickhouse-server 2>/dev/null || true

supervise() {
  local name="$1"; shift
  (
    while true; do
      "$@"
      log "$name exited (code $?) — restarting in 3s"
      sleep 3
    done
  ) &
}

supervise clickhouse su -s /bin/bash clickhouse -c \
  "/usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml"

log "waiting for clickhouse..."
for _ in $(seq 1 60); do
  clickhouse-client --query "SELECT 1" >/dev/null 2>&1 && break
  sleep 1
done
clickhouse-client --query "CREATE DATABASE IF NOT EXISTS otel" 2>/dev/null \
  || log "warning: clickhouse not ready yet (collector will retry)"

supervise otelcol /usr/local/bin/otelcol-contrib --config /etc/otelcol/config.yaml

mkdir -p /var/lib/grafana /var/log/grafana
chown -R grafana:grafana /var/lib/grafana /var/log/grafana 2>/dev/null || true
export GF_SERVER_HTTP_ADDR=127.0.0.1 \
       GF_SERVER_HTTP_PORT=3000 \
       GF_PATHS_DATA=/var/lib/grafana \
       GF_PATHS_PLUGINS=/var/lib/grafana/plugins \
       GF_PATHS_LOGS=/var/log/grafana \
       GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
       GF_AUTH_ANONYMOUS_ENABLED="${GF_AUTH_ANONYMOUS_ENABLED:-true}" \
       GF_AUTH_ANONYMOUS_ORG_ROLE="${GF_AUTH_ANONYMOUS_ORG_ROLE:-Viewer}" \
       GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana-dashboards/agent-work.json
supervise grafana su -s /bin/bash grafana -c \
  "cd /usr/share/grafana && /usr/share/grafana/bin/grafana server --homepath /usr/share/grafana --config /etc/grafana/grafana.ini"

supervise nginx nginx -g "daemon off;"

log "all services launched — listening on :8080"
wait
