# 防火牆套用專用 image：由 host 從本 repo 建置（lib/helpers.sh 的 ensure_firewall_image）
# 以 --network container:<開發容器> 共用網路命名空間套用規則；開發容器內的 AI 無法修改此 image 或規則
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables ipset dnsutils curl ca-certificates jq iproute2 \
    && (apt-get install -y --no-install-recommends aggregate || echo "WARN: aggregate not available") \
    && rm -rf /var/lib/apt/lists/*

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 755 /usr/local/bin/init-firewall.sh

# 無參數：完整套用；--refresh：只刷新白名單
ENTRYPOINT ["/usr/local/bin/init-firewall.sh"]
