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

# 確認 jq 存在（host 上需要安裝，用於安全解析 JSON）
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed on host machine"
    echo "Install with: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

# ============================================================
# 從 project-config.json 讀取 port 設定（純資料，非 Bootstrap 產生的代碼）
# ============================================================
PORT_ARGS=""
PORT_ENV=""
PORT_SUMMARY=""
# 專案容器可用 port 範圍（避開常見服務 port）
PORT_MIN=10000
PORT_MAX=19999
PORT_INDEX=0
MAX_PORTS=20

CONFIG_FILE="${PROJECT_DIR}/project-config.json"
if [ -f "$CONFIG_FILE" ]; then
    # 使用 jq 安全解析 JSON（避免 grep 注入風險）
    PORTS=$(jq -r '.ports[]? // empty' "$CONFIG_FILE" 2>/dev/null || true)
    for port in $PORTS; do
        # 上限檢查：防止惡意 config 指定過多 port 導致 DoS
        if [ "$PORT_INDEX" -ge "$MAX_PORTS" ]; then
            echo "WARNING: Maximum $MAX_PORTS ports reached, ignoring remaining"
            break
        fi
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            actual_port=$PORT_MIN
            # 自動尋找可用且不衝突的 port
            while ss -tlnp 2>/dev/null | grep -q ":${actual_port} "; do
                actual_port=$((actual_port + 1))
                if [ "$actual_port" -gt "$PORT_MAX" ]; then
                    echo "ERROR: No available port in range ${PORT_MIN}-${PORT_MAX}"
                    exit 1
                fi
            done
            # 下次從此 port 之後開始找（避免多 port 時分配到同一個）
            PORT_MIN=$((actual_port + 1))
            # host 和 container 使用同一個 port（方便本機存取）
            PORT_ARGS="${PORT_ARGS} -p ${actual_port}:${actual_port}"
            PORT_ENV="${PORT_ENV} -e PORT_${PORT_INDEX}=${actual_port}"
            PORT_SUMMARY="${PORT_SUMMARY}  - ${actual_port}
"
            PORT_INDEX=$((PORT_INDEX + 1))
        fi
    done
    # 設定主 port 環境變數（容器內 $PORT 即可取得）
    if [ "$PORT_INDEX" -gt 0 ]; then
        FIRST_PORT=$(printf '%s' "$PORT_SUMMARY" | head -1 | grep -o '[0-9]\+')
        PORT_ENV="${PORT_ENV} -e PORT=${FIRST_PORT}"
    fi
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
    --cap-drop=ALL \
    --security-opt no-new-privileges \
    --restart no \
    ${PORT_ARGS} ${PORT_ENV} \
    -v "${PROJECT_DIR}/repo:/workspace" \
    -v "${PROJECT_DIR}/data:/data" \
    -v "${PROJECT_DIR}/secrets:/secrets:ro" \
    -v "${CRED_FILE}:/home/node/.claude/.credentials.json:ro" \
    "${IMAGE}" \
    sleep infinity

# ============================================================
# 驗證容器啟動成功（捕獲 port binding 失敗等問題）
# ============================================================
sleep 1
CONTAINER_STATE=$(docker inspect --format='{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo "false")
if [ "$CONTAINER_STATE" != "true" ]; then
    echo "ERROR: Container failed to start. Possible port binding conflict."
    echo "Check: docker logs ${CONTAINER}"
    docker rm -f "${CONTAINER}" 2>/dev/null || true
    exit 1
fi

# ============================================================
# 透過外部一次性容器套用防火牆（共享 network namespace）
# 容器本身無 NET_ADMIN，無法自行修改防火牆規則
# ============================================================
echo "Initializing firewall via external container..."
if ! docker run --rm \
    --user root \
    --cap-drop=ALL \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --network "container:${CONTAINER}" \
    "${IMAGE}" \
    /usr/local/bin/init-firewall.sh; then
    echo "ERROR: Firewall initialization failed."
    echo "Stopping container for safety — do not use without firewall."
    docker stop "${CONTAINER}" 2>/dev/null || true
    exit 1
fi

# ============================================================
# MCP Search Server 連線設定
# ============================================================
MCP_SEARCH="false"
if [ -f "$CONFIG_FILE" ]; then
    MCP_SEARCH=$(jq -r '.mcp_search // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
fi

if [ "$MCP_SEARCH" = "true" ]; then
    MCP_PORT="${MCP_SEARCH_PORT:-9100}"
    if ! docker ps -q -f "name=claude-mcp-search" | grep -q .; then
        echo ""
        echo "WARNING: MCP Search Server (claude-mcp-search) is not running."
        echo "Search capability will not be available."
        echo "Start it with: docker run -d --name claude-mcp-search -p ${MCP_PORT}:9100 claude-mcp-search:latest"
    else
        # 取得 host IP（容器透過此 IP 連到 MCP Server）
        MCP_HOST_IP=$(docker exec "${CONTAINER}" sh -c "ip route | grep default | cut -d' ' -f3")
        if [ -n "$MCP_HOST_IP" ]; then
            # 寫入 .mcp.json（Claude Code 自動讀取此檔案載入 MCP 工具）
            docker exec "${CONTAINER}" sh -c "cat > /workspace/.mcp.json << MCPEOF
{
  \"search\": {
    \"type\": \"http\",
    \"url\": \"http://${MCP_HOST_IP}:${MCP_PORT}/mcp\"
  }
}
MCPEOF"
            # 驗證 MCP Server 可達（從容器內部測試）
            if docker exec "${CONTAINER}" sh -c "curl -sf --connect-timeout 3 http://${MCP_HOST_IP}:${MCP_PORT}/health >/dev/null 2>&1"; then
                MCP_CONFIGURED="true"
            else
                echo "WARNING: MCP Search Server is running but not reachable at http://${MCP_HOST_IP}:${MCP_PORT}"
                echo "Check: port binding, firewall rules, or MCP server logs."
                docker exec "${CONTAINER}" rm -f /workspace/.mcp.json
            fi
        else
            echo "WARNING: Could not detect host IP for MCP connection."
        fi
    fi
fi

echo ""
echo "✓ Container started: ${CONTAINER}"
echo "✓ Network: net-${PROJECT_NAME}"
echo "✓ Firewall active (externally applied, tamper-proof)"
if [ -n "$PORT_SUMMARY" ]; then
    echo "✓ Ports:"
    printf '%s' "$PORT_SUMMARY"
fi
if [ "${MCP_CONFIGURED:-}" = "true" ]; then
    echo "✓ MCP Search enabled (http://${MCP_HOST_IP}:${MCP_PORT})"
fi
echo ""
echo "Next: ./scripts/enter.sh"
echo "Then: claude --dangerously-skip-permissions"
