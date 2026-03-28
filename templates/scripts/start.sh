#!/usr/bin/env bash
set -euo pipefail
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_DIR="{{PROJECT_DIR}}"
CONTAINER="devcontainer-${PROJECT_NAME}"
IMAGE="devcontainer-${PROJECT_NAME}:latest"

# 確認 credentials 存在
CRED_FILE="${HOME}/.claude/.credentials.json"
if [ ! -f "$CRED_FILE" ]; then
    echo "Error: Claude credentials not found at $CRED_FILE"
    echo "Run 'claude login' on host first."
    exit 1
fi

# ============================================================
# 從 project-config.json 讀取 port 設定（純資料，非 Bootstrap 產生的代碼）
# ============================================================
PORT_ARGS=""
PORT_SUMMARY=""
# 專案容器可用 port 範圍（避開常見服務 port）
# 1024-3000:  常見開發工具（webpack 2999, React 3000 等）
# 3306:       MySQL
# 5432:       PostgreSQL
# 5672/5673:  RabbitMQ
# 6379:       Redis
# 8080-8090:  常見 HTTP 代理/應用伺服器
# 8443:       HTTPS 替代
# 9090:       Prometheus
# 9200:       Elasticsearch
# 27017:      MongoDB
PORT_MIN=10000
PORT_MAX=19999

CONFIG_FILE="${PROJECT_DIR}/project-config.json"
if [ -f "$CONFIG_FILE" ]; then
    # 壓成單行後解析，避免多行 JSON 導致 grep 失敗
    PORTS=$(tr -d '\n\r\t' < "$CONFIG_FILE" | grep -oP '"ports"\s*:\s*\[\K[^\]]*' 2>/dev/null | tr -d ' "' | tr ',' '\n' || true)
    for port in $PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            # 將設定的 port 映射到安全範圍內
            actual_port=$PORT_MIN
            # 若 port 被佔用，自動尋找下一個可用 port
            while ss -tlnp 2>/dev/null | grep -q ":${actual_port} "; do
                actual_port=$((actual_port + 1))
                if [ "$actual_port" -gt "$PORT_MAX" ]; then
                    echo "ERROR: No available port in range ${PORT_MIN}-${PORT_MAX}"
                    exit 1
                fi
            done
            PORT_ARGS="${PORT_ARGS} -p ${actual_port}:${port}"
            PORT_SUMMARY="${PORT_SUMMARY}  - localhost:${actual_port} → container:${port}\n"
        fi
    done
fi

# 建立 network（如不存在）
docker network create "net-${PROJECT_NAME}" 2>/dev/null || true

# 移除舊容器（如存在）
docker rm -f "${CONTAINER}" 2>/dev/null || true

# ============================================================
# 啟動容器（不授予 NET_ADMIN — 防火牆由外部套用，容器內無法關閉）
# ============================================================
docker run -d \
    --name "${CONTAINER}" \
    --hostname "${PROJECT_NAME}-dev" \
    --network "net-${PROJECT_NAME}" \
    ${PORT_ARGS} \
    -v "${PROJECT_DIR}/repo:/workspace" \
    -v "${PROJECT_DIR}/data:/data" \
    -v "${PROJECT_DIR}/secrets:/secrets:ro" \
    -v "${CRED_FILE}:/home/node/.claude/.credentials.json:ro" \
    --restart unless-stopped \
    "${IMAGE}" \
    sleep infinity

# ============================================================
# 透過外部一次性容器套用防火牆（共享 network namespace）
# 容器本身無 NET_ADMIN，無法自行修改防火牆規則
# ============================================================
echo "Initializing firewall via external container..."
if ! docker run --rm \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --network "container:${CONTAINER}" \
    "${IMAGE}" \
    sudo /usr/local/bin/init-firewall.sh; then
    echo "ERROR: Firewall initialization failed."
    echo "Stopping container for safety — do not use without firewall."
    docker stop "${CONTAINER}" 2>/dev/null || true
    exit 1
fi

echo ""
echo "✓ Container started: ${CONTAINER}"
echo "✓ Network: net-${PROJECT_NAME}"
echo "✓ Firewall active (externally applied, tamper-proof)"
if [ -n "$PORT_SUMMARY" ]; then
    echo "✓ Ports:"
    echo -e "$PORT_SUMMARY"
fi
echo ""
echo "Next: ./scripts/enter.sh"
echo "Then: claude --dangerously-skip-permissions"
