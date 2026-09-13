#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# ============================================================
# 開發容器防火牆（由 host 建置的 claude-dev-firewall image 執行）
#   init-firewall.sh            完整套用：start.sh 在容器啟動後執行
#   init-firewall.sh --refresh  只重建白名單 ipset 並原子交換，不動 iptables 規則：scripts/firewall.sh
#   init-firewall.sh --check    只檢查防火牆是否仍在作用中：scripts/enter.sh
# 以 --network container:<開發容器> 共用網路命名空間，規則作用在開發容器上
# ============================================================
MODE="apply"
case "${1:-}" in
    "") ;;
    --refresh) MODE="refresh" ;;
    --check)
        # 規則存在於容器的 network namespace；容器若被 docker start/restart 直接重啟，規則就不見了
        if ipset list -n allowed-domains >/dev/null 2>&1 && iptables -S OUTPUT 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; then
            exit 0
        fi
        echo "Firewall is not active in this container"
        exit 1
        ;;
    *)
        echo "Usage: init-firewall.sh [--refresh|--check]"
        exit 1
        ;;
esac

DOMAIN_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'

# 預設放行的網域
# - Claude Code：api.anthropic.com、platform.claude.com（OAuth token 交換/更新）、sentry.io、statsig.com（對齊官方 devcontainer）
# - Codex / OpenAI：API + ChatGPT 訂閱登入 + codex backend
# - 套件來源：npm、pip、go、cargo（含 sparse index）
# - GitHub 封存檔下載（codeload；其餘 GitHub 網段由 api.github.com/meta 取得）
# - IDE：VS Code marketplace、更新、VS Code Server 下載
# 單一網域解析失敗只警告、跳過（非致命），避免某個網域暫時解不出就讓整個防火牆失敗
# 專案需要其他網域時：在 host 的 project-config.json 加入 extra_allowed_domains，再執行 scripts/firewall.sh
DEFAULT_DOMAINS=(
    "registry.npmjs.org"
    "api.openai.com"
    "auth.openai.com"
    "chatgpt.com"
    "openai.com"
    "api.anthropic.com"
    "platform.claude.com"
    "sentry.io"
    "statsig.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    "vscode.download.prss.microsoft.com"
    "pypi.org"
    "files.pythonhosted.org"
    "proxy.golang.org"
    "sum.golang.org"
    "crates.io"
    "static.crates.io"
    "index.crates.io"
    "codeload.github.com"
)

# 專案額外放行的網域（start.sh / firewall.sh 從 project-config.json 讀出、驗證後以空白分隔傳入；此處再驗證一次）
EXTRA_DOMAINS=()
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
    IFS=' ' read -r -a EXTRA_DOMAINS <<< "$EXTRA_ALLOWED_DOMAINS"
    for domain in "${EXTRA_DOMAINS[@]}"; do
        if [[ ! "$domain" =~ $DOMAIN_RE ]]; then
            echo "ERROR: Invalid domain in EXTRA_ALLOWED_DOMAINS: $domain"
            exit 1
        fi
    done
fi

# 將 GitHub 網段與所有白名單網域的 IP 加入指定的 ipset
populate_allowed_set() {
    local set_name="$1" gh_ranges cidr domain ips ip attempt

    echo "Fetching GitHub IP ranges..."
    gh_ranges=$(curl -sf --connect-timeout 10 https://api.github.com/meta) || gh_ranges=""
    if [ -z "$gh_ranges" ]; then
        echo "ERROR: Failed to fetch GitHub IP ranges"
        exit 1
    fi

    if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
        echo "ERROR: GitHub API response missing required fields"
        exit 1
    fi

    echo "Processing GitHub IPs..."
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
            exit 1
        fi
        echo "Adding GitHub range $cidr"
        ipset add "$set_name" "$cidr" timeout 0
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[] | select(contains(":") | not)' | (aggregate -q 2>/dev/null || sort -u))

    for domain in "${DEFAULT_DOMAINS[@]}" "${EXTRA_DOMAINS[@]}"; do
        echo "Resolving $domain..."
        # 上游 DNS 偶爾會對快取未命中的查詢回傳空結果（TTL 很短的 CDN 網域較常見），所以失敗時重試
        ips=""
        for attempt in 1 2 3; do
            ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}' || true)
            if [ -n "$ips" ]; then
                break
            fi
            if [ "$attempt" -lt 3 ]; then
                sleep "$attempt"
            fi
        done
        if [ -z "$ips" ]; then
            echo "WARNING: Failed to resolve $domain after 3 attempts — skipping (non-fatal)"
            continue
        fi

        while read -r ip; do
            if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "ERROR: Invalid IP from DNS for $domain: $ip"
                exit 1
            fi
            echo "Adding $ip for $domain"
            ipset add "$set_name" "$ip" timeout 0 2>/dev/null || true
        done < <(echo "$ips")
    done
}

# 驗證防火牆行為；失敗時回傳 1
verify_firewall() {
    local canary_allowed=false ip
    echo "Verifying firewall rules..."

    # 1. 未放行的網站必須連不到（若 example.com 的 IP 剛好被白名單涵蓋，就跳過這項）
    for ip in $(dig +short A example.com 2>/dev/null | grep -E '^[0-9.]+$' || true); do
        if ipset test allowed-domains "$ip" >/dev/null 2>&1; then
            canary_allowed=true
        fi
    done
    if [ "$canary_allowed" = true ]; then
        echo "Skipping blocked-site check: example.com is covered by the allowlist"
    elif curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - was able to reach https://example.com"
        return 1
    else
        echo "Firewall verification passed - unable to reach https://example.com as expected"
    fi

    # 2. 只能透過 Docker 內建 DNS 查詢，直連外部 DNS 伺服器必須失敗
    if dig +time=2 +tries=1 @1.1.1.1 example.com >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - external DNS server 1.1.1.1 is reachable"
        return 1
    else
        echo "Firewall verification passed - external DNS servers are blocked"
    fi

    # 3. 白名單內的服務必須連得到
    if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
        return 1
    else
        echo "Firewall verification passed - able to reach https://api.github.com as expected"
    fi
}

# ============================================================
# --refresh：以新的 ipset 原子替換白名單（容器與執行中的程式不受影響）
# ============================================================
if [ "$MODE" = "refresh" ]; then
    if ! ipset list -n allowed-domains >/dev/null 2>&1; then
        echo "ERROR: Firewall is not initialized in this container. Run scripts/start.sh first."
        exit 1
    fi
    ipset destroy allowed-domains-new 2>/dev/null || true
    ipset create allowed-domains-new hash:net timeout 3600
    populate_allowed_set allowed-domains-new
    # iptables 規則引用的 set 名稱不變，交換瞬間生效，沒有無規則的空窗
    ipset swap allowed-domains-new allowed-domains
    if ! verify_firewall; then
        echo "Restoring the previous allowlist..."
        ipset swap allowed-domains-new allowed-domains
        ipset destroy allowed-domains-new
        exit 1
    fi
    ipset destroy allowed-domains-new
    echo "Firewall allowlist refreshed"
    exit 0
fi

# ============================================================
# 完整套用
# ============================================================

# 1. Save complete Docker NAT rules BEFORE any flushing
# This captures both chain rules AND jump rules (OUTPUT → DOCKER_OUTPUT, etc.)
DOCKER_NAT_SAVE=$(iptables-save -t nat || true)

# Extract Docker DNS-related chains and their jump rules
DOCKER_NAT_RESTORE=""
if echo "$DOCKER_NAT_SAVE" | grep -q "DOCKER_OUTPUT\|DOCKER_POSTROUTING"; then
    # Build a minimal iptables-restore snippet for Docker DNS
    DOCKER_NAT_RESTORE=$(echo "$DOCKER_NAT_SAVE" | awk '
        /^:DOCKER_OUTPUT / || /^:DOCKER_POSTROUTING / { print; next }
        /-j DOCKER_OUTPUT/ || /-j DOCKER_POSTROUTING/ { print; next }
        /-A DOCKER_OUTPUT / || /-A DOCKER_POSTROUTING / { print; next }
    ')
fi

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy allowed-domains-new 2>/dev/null || true

# 2. Restore Docker DNS NAT rules (chains + jump rules)
if [ -n "$DOCKER_NAT_RESTORE" ]; then
    echo "Restoring Docker DNS NAT rules..."
    # Recreate chains first
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    # Restore chain rules and jump rules line by line (用 xargs 確保正確分割參數)
    echo "$DOCKER_NAT_RESTORE" | grep -v '^:' | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS NAT rules to restore"
fi

# DNS：只放行 Docker 內建 DNS（自訂網路的容器一律使用 127.0.0.11），直連外部 DNS 伺服器會被擋
iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d 127.0.0.11 --dport 53 -j ACCEPT
iptables -A INPUT -p udp -s 127.0.0.11 --sport 53 -j ACCEPT
iptables -A INPUT -p tcp -s 127.0.0.11 --sport 53 -j ACCEPT
# Allow localhost（內建 DNS 經 NAT 轉換後也走 loopback）
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
# SSH 不再對任意主機開放：白名單 IP（含 GitHub）的所有 port 由下方 allowed-domains 規則放行

# Create ipset with CIDR support and entry timeout (3600s = 1hr)
ipset create allowed-domains hash:net timeout 3600
populate_allowed_set allowed-domains

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3 || true)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
# 允許整個 host 網段（容器透過此網段連到 host 服務，例如 MCP Search Server）
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# OPTIONAL（mcp-access）：允許連到同機筆記 MCP 的內部網路（172.30.0.0/24）。
# 未建立該網路 / 未 attach 時此規則無害（該網段不存在）。回應走 ESTABLISHED，故只需 OUTPUT。
iptables -A OUTPUT -d 172.30.0.0/24 -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# ============================================================
# IPv6 防火牆（全面封鎖 — 只允許 loopback）
# ============================================================
echo "Configuring IPv6 firewall..."
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
echo "IPv6 firewall: all non-loopback traffic blocked"

echo "Firewall configuration complete"
if ! verify_firewall; then
    exit 1
fi
