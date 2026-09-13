#!/usr/bin/env bash
set -euo pipefail
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_DIR="{{PROJECT_DIR}}"
CONTAINER="devcontainer-${PROJECT_NAME}"
IMAGE="devcontainer-${PROJECT_NAME}:latest"

# 確認 jq 存在（host 上需要安裝，用於安全解析 JSON）
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed on host machine"
    echo "Install with: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

CONFIG_FILE="${PROJECT_DIR}/project-config.json"

# ============================================================
# Agent 選擇（claude | codex）— 決定認證、持久化、MCP 設定方式
# ============================================================
AGENT="claude"
if [ -f "$CONFIG_FILE" ]; then
    _agent=$(jq -r '.agent // "claude"' "$CONFIG_FILE" 2>/dev/null || echo "claude")
    [ -n "$_agent" ] && AGENT="$_agent"
fi

# ============================================================
# Claude Code OAuth token（僅 agent=claude 時需要）
# ============================================================
TOKEN_FILE="${HOME}/.claude/.oauth-token"
if [ "$AGENT" = "claude" ]; then
    if [ ! -f "$TOKEN_FILE" ]; then
        echo "Error: Claude OAuth token not found at $TOKEN_FILE"
        echo "Run 'claude setup-token' on host first, then save the token:"
        echo "  echo 'YOUR_TOKEN' > ~/.claude/.oauth-token && chmod 600 ~/.claude/.oauth-token"
        exit 1
    fi
    TOKEN_PERMS=$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%Lp' "$TOKEN_FILE" 2>/dev/null)
    if [ "$TOKEN_PERMS" != "600" ]; then
        echo "Error: Token file permissions are $TOKEN_PERMS (must be 600)"
        echo "Fix with: chmod 600 $TOKEN_FILE"
        exit 1
    fi
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

# 容器使用者（預設 node，可在 project-config.json 中覆寫）
CONTAINER_USER="node"
if [ -f "$CONFIG_FILE" ]; then
    _user=$(jq -r '.container_user // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$_user" ] && CONTAINER_USER="$_user"
fi
CONTAINER_HOME="/home/${CONTAINER_USER}"

# ============================================================
# 準備 agent 持久化目錄（session + 登入狀態，每個專案必備）
#   claude → claude-data 掛載為 ~/.claude
#   codex  → codex-data  掛載為 ~/.codex（login state auth.json + config.toml）
# ============================================================
AGENT_MOUNT=""
if [ "$AGENT" = "codex" ]; then
    mkdir -p -m 700 "${PROJECT_DIR}/codex-data"
    AGENT_MOUNT="-v ${PROJECT_DIR}/codex-data:${CONTAINER_HOME}/.codex"
    # Codex 登入：在容器內自行執行 `codex login` 即可；登入狀態持久化於 codex-data（掛載為 ~/.codex）。
else
    mkdir -p -m 700 "${PROJECT_DIR}/claude-data"
    if [ ! -f "${PROJECT_DIR}/claude-data/settings.json" ]; then
        echo '{"model":"opus"}' > "${PROJECT_DIR}/claude-data/settings.json"
    fi
    AGENT_MOUNT="-v ${PROJECT_DIR}/claude-data:${CONTAINER_HOME}/.claude"
fi

# gstack 持久化（僅在啟用 gstack 時）
GSTACK_ENABLED="false"
if [ -f "$CONFIG_FILE" ]; then
    GSTACK_ENABLED=$(jq -r '.gstack // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
fi
GSTACK_MOUNT=""
if [ "$GSTACK_ENABLED" = "true" ]; then
    mkdir -p -m 700 "${PROJECT_DIR}/gstack-data"
    GSTACK_MOUNT="-v ${PROJECT_DIR}/gstack-data:${CONTAINER_HOME}/.gstack"
fi

# GPU 支援（需要 host 已安裝 nvidia-container-toolkit）
GPU_FLAG=""
GPU_ENABLED="false"
if [ -f "$CONFIG_FILE" ]; then
    GPU_ENABLED=$(jq -r '.gpu // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
fi
if [ "$GPU_ENABLED" = "true" ]; then
    if command -v nvidia-smi &>/dev/null; then
        GPU_FLAG="--gpus all"
        echo "GPU support enabled."
    else
        echo "WARNING: gpu=true in config but nvidia-smi not found on host. Skipping GPU."
    fi
fi

# ============================================================
# 準備 Claude OAuth token（檔案掛載，不暴露在環境變數；僅 agent=claude）
# ============================================================
if [ "$AGENT" = "claude" ]; then
    cp "$TOKEN_FILE" "${PROJECT_DIR}/claude-data/.oauth-token"
    chmod 600 "${PROJECT_DIR}/claude-data/.oauth-token"
fi

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
    ${GPU_FLAG} \
    ${PORT_ARGS} ${PORT_ENV} \
    -v "${PROJECT_DIR}/repo:/workspace" \
    -v "${PROJECT_DIR}/data:/data" \
    -v "${PROJECT_DIR}/secrets:/secrets:ro" \
    ${AGENT_MOUNT} \
    ${GSTACK_MOUNT} \
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

# 設定 token 環境變數載入（透過 profile.d，不暴露在 docker inspect；僅 agent=claude）
if [ "$AGENT" = "claude" ]; then
    docker exec -u root "${CONTAINER}" sh -c \
        "echo 'export CLAUDE_CODE_OAUTH_TOKEN=\$(cat ${CONTAINER_HOME}/.claude/.oauth-token 2>/dev/null)' > /etc/profile.d/claude-token.sh && chmod 644 /etc/profile.d/claude-token.sh"
fi

# （筆記 MCP 的 attach/設定移到防火牆之後，見下方 notes_mcp 區塊 — 防火牆規則為靜態，不需先 attach）

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

# 取得 host IP（容器透過此 IP 連到 host 上的 MCP server）
HOST_IP=$(docker exec "${CONTAINER}" sh -c "ip route | grep default | cut -d' ' -f3" || true)

# ============================================================
# MCP 設定（base）
#   codex  → 寫入 ~/.codex/config.toml（預設設定 + 選用的 search；筆記 MCP 於下方追加）
#   claude → 寫入 /workspace/.mcp.json（search；筆記 MCP 於下方合併）
# ============================================================
MCP_SEARCH=$(jq -r '.mcp_search // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
MCP_SEARCH_PORT_VAL="${MCP_SEARCH_PORT:-9100}"

if [ "$AGENT" = "codex" ]; then
    # ---- 組出 config.toml（每次 start 覆寫；登入狀態在 auth.json，不受影響）----
    # 容器本身即為沙箱（防火牆隔離、無特權），故關閉 Codex 內建 sandbox 並免核准，
    # 對齊 Claude 端 `--dangerously-skip-permissions` 的無阻斷開發體驗。
    CODEX_TOML="# 由 start.sh 自動產生（每次 start 覆寫）
# 登入狀態存於同目錄的 auth.json，不受此檔影響。自訂設定請勿寫在此檔。
approval_policy = \"never\"
sandbox_mode = \"danger-full-access\"
"
    if [ "$MCP_SEARCH" = "true" ] && docker ps -q -f "name=claude-mcp-search" | grep -q . && [ -n "$HOST_IP" ]; then
        CODEX_TOML="${CODEX_TOML}
[mcp_servers.search]
url = \"http://${HOST_IP}:${MCP_SEARCH_PORT_VAL}/mcp\"
"
    fi

    # 寫入容器內 ~/.codex/config.toml（以容器使用者身分，確保擁有權正確；ai-note-live 於下方 notes 區塊追加）
    printf '%s' "$CODEX_TOML" | docker exec -i -u "${CONTAINER_USER}" "${CONTAINER}" sh -c "cat > ${CONTAINER_HOME}/.codex/config.toml"
elif [ "$MCP_SEARCH" = "true" ]; then
    # ---- Claude Code：沿用 .mcp.json ----
    if ! docker ps -q -f "name=claude-mcp-search" | grep -q .; then
        echo ""
        echo "WARNING: MCP Search Server (claude-mcp-search) is not running."
        echo "Search capability will not be available."
        echo "Start it with: docker run -d --name claude-mcp-search -p ${MCP_SEARCH_PORT_VAL}:9100 claude-mcp-search:latest"
    elif [ -n "$HOST_IP" ]; then
        docker exec "${CONTAINER}" sh -c "cat > /workspace/.mcp.json << MCPEOF
{
  \"mcpServers\": {
    \"search\": {
      \"type\": \"http\",
      \"url\": \"http://${HOST_IP}:${MCP_SEARCH_PORT_VAL}/mcp\"
    }
  }
}
MCPEOF"
        if docker exec "${CONTAINER}" sh -c "curl -sf --connect-timeout 3 http://${HOST_IP}:${MCP_SEARCH_PORT_VAL}/health >/dev/null 2>&1"; then
            MCP_CONFIGURED="true"
        else
            echo "WARNING: MCP Search Server is running but not reachable at http://${HOST_IP}:${MCP_SEARCH_PORT_VAL}"
            docker exec "${CONTAINER}" rm -f /workspace/.mcp.json
        fi
    else
        echo "WARNING: Could not detect host IP for MCP connection."
    fi
fi

# ============================================================
# 筆記 MCP（同機 mcp-access 內網 → production ai-note；server 名 ai-note-live）
# 依 /srv/data/projects/ai-note/repo/docs/mcp-access-recipe.md（authoritative）
# 預設開啟；某專案不接就在 project-config.json 設 "notes_mcp": false
# ============================================================
NOTES_MCP=$(jq -r '.notes_mcp // true' "$CONFIG_FILE" 2>/dev/null || echo "true")
NOTES_URL="http://ainote-mcp:47823/mcp"
NOTES_CONFIGURED=""
if [ "$NOTES_MCP" = "true" ]; then
    # token 來源：專案專屬優先（需要 private/admin 時個別覆蓋），否則用全機共用那枚
    NOTES_TOKEN_FILE="${PROJECT_DIR}/secrets/notes-token"
    [ -r "$NOTES_TOKEN_FILE" ] || NOTES_TOKEN_FILE="${HOME}/ai-note-secrets/dev-token"
    if [ ! -r "$NOTES_TOKEN_FILE" ]; then
        echo "WARNING: 找不到 ${HOME}/ai-note-secrets/dev-token（見 mcp-access-recipe.md Part A 步驟 4/5），跳過筆記 MCP"
    elif ! docker network inspect mcp-access >/dev/null 2>&1; then
        echo "WARNING: mcp-access 網路不存在（見 recipe Part A），跳過筆記 MCP"
    else
        docker network connect mcp-access "${CONTAINER}" 2>/dev/null || true
        NOTES_TOKEN=$(cat "$NOTES_TOKEN_FILE")
        if [ "$AGENT" = "codex" ]; then
            # Codex：token 放進 codex-data 供 env 載入，config.toml 用 bearer_token_env_var（不落地）
            printf '%s' "$NOTES_TOKEN" > "${PROJECT_DIR}/codex-data/.notes-token"
            chmod 600 "${PROJECT_DIR}/codex-data/.notes-token"
            docker exec -u root "${CONTAINER}" sh -c \
                "echo 'export NOTES_TOKEN=\$(cat ${CONTAINER_HOME}/.codex/.notes-token 2>/dev/null)' > /etc/profile.d/notes-token.sh && chmod 644 /etc/profile.d/notes-token.sh"
            docker exec -i -u "${CONTAINER_USER}" "${CONTAINER}" sh -c "cat >> ${CONTAINER_HOME}/.codex/config.toml" <<'TOML'

[mcp_servers.ai-note-live]
url = "http://ainote-mcp:47823/mcp"
bearer_token_env_var = "NOTES_TOKEN"
TOML
        else
            # Claude Code：合併進 /workspace/.mcp.json（保留既有 MCP 設定不覆蓋）
            docker exec -u "${CONTAINER_USER}" -e NOTES_TOKEN="$NOTES_TOKEN" "${CONTAINER}" node -e '
const fs=require("fs"), f="/workspace/.mcp.json";
let j={mcpServers:{}}; try { j=JSON.parse(fs.readFileSync(f,"utf8")); } catch(e){}
j.mcpServers = j.mcpServers || {};
j.mcpServers["ai-note-live"] = { type:"http", url:"http://ainote-mcp:47823/mcp", headers:{ Authorization:"Bearer "+process.env.NOTES_TOKEN } };
fs.writeFileSync(f, JSON.stringify(j,null,2));
'
        fi
        # 認證感知可達性檢查（POST tools/list 帶 token，期望 200；--max-time 防 SSE 卡住；非致命）
        HTTP_CODE=$(docker exec -e NT="$NOTES_TOKEN" "${CONTAINER}" sh -c "
          curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
            -XPOST -H 'content-type: application/json' \
            -H 'accept: application/json, text/event-stream' \
            -H \"authorization: Bearer \${NT}\" \
            -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}' \
            '${NOTES_URL}'
        " 2>/dev/null || true)
        HTTP_CODE=${HTTP_CODE:-000}
        case "$HTTP_CODE" in
            200) NOTES_CONFIGURED="true" ;;
            401) echo "WARNING: ai-note 回 401 — token 未生效（tokens.json 沒有此 token，或改了但沒 restart ai-note）。" ;;
            403) echo "WARNING: ai-note 回 403 — ainote-mcp:47823 不在 AINOTE_ALLOWED_HOSTS。" ;;
            000) echo "WARNING: 連不到 ai-note（逾時/拒絕）— mcp-access 未就緒、防火牆未放行 172.30.0.0/24、或 server 只綁 127.0.0.1。" ;;
            *)   echo "WARNING: ai-note 非預期回應 HTTP ${HTTP_CODE}（${NOTES_URL}）。" ;;
        esac
    fi
fi

echo ""
echo "✓ Container started: ${CONTAINER}"
echo "✓ Agent: ${AGENT}"
echo "✓ Network: net-${PROJECT_NAME}"
echo "✓ Firewall active (externally applied, tamper-proof)"
if [ -n "$PORT_SUMMARY" ]; then
    echo "✓ Ports:"
    printf '%s' "$PORT_SUMMARY"
fi
if [ "${NOTES_CONFIGURED:-}" = "true" ]; then
    echo "✓ Notes MCP (ai-note-live) enabled + verified 200 (${NOTES_URL})"
elif [ "${NOTES_MCP:-true}" = "true" ]; then
    echo "• Notes MCP: 設定已嘗試寫入，但未驗證成功（見上方 WARNING）"
fi
if [ "${MCP_CONFIGURED:-}" = "true" ]; then
    echo "✓ MCP Search enabled (http://${HOST_IP}:${MCP_SEARCH_PORT_VAL})"
fi
echo ""
echo "Next: ./scripts/enter.sh"
if [ "$AGENT" = "codex" ]; then
    echo "Then: codex   (首次在容器內執行 'codex login' 完成 ChatGPT 登入；登入狀態持久化於 codex-data)"
else
    echo "Then: claude --dangerously-skip-permissions"
fi
