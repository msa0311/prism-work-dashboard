# prism-work-dashboard — all-in-one agent-work telemetry stack:
# OTel Collector (OTLP/HTTP ingest) -> ClickHouse (storage) -> Grafana (dashboard),
# fronted by nginx on ONE port (8080) so it fits a Lens agents sandbox
# (single exposed port, HTTP/1.1 ingress tunnel).

FROM ubuntu:24.04

ARG OTELCOL_VERSION=0.120.0
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive

# ClickHouse + Grafana apt repos, then all four components in one layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg nginx gettext-base \
    && curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key \
        | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
        > /etc/apt/sources.list.d/clickhouse.list \
    && curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/grafana.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        clickhouse-server clickhouse-client grafana \
    && rm -rf /var/lib/apt/lists/*

# OTel Collector (contrib — has the clickhouse exporter).
RUN curl -fsSL -o /tmp/otelcol.tar.gz \
        "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_${TARGETARCH}.tar.gz" \
    && tar -xzf /tmp/otelcol.tar.gz -C /usr/local/bin otelcol-contrib \
    && rm /tmp/otelcol.tar.gz

# Grafana ClickHouse datasource plugin.
RUN grafana cli --pluginsDir /var/lib/grafana/plugins plugins install grafana-clickhouse-datasource \
    && chown -R grafana:grafana /var/lib/grafana

COPY otel-collector/config.yaml /etc/otelcol/config.yaml
COPY clickhouse-overrides.xml   /etc/clickhouse-server/config.d/prism.xml
COPY grafana/provisioning/      /etc/grafana/provisioning/
COPY grafana/dashboards/        /var/lib/grafana-dashboards/
COPY nginx.conf.template        /etc/nginx/nginx.conf.template
COPY entrypoint.sh              /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ClickHouse data lives here — mount the sandbox PVC / docker volume at this path.
VOLUME ["/var/lib/clickhouse"]

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
