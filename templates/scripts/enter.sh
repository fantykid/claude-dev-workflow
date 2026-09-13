#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="{{PROJECT_DIR}}"
REPO_DIR="{{REPO_DIR}}"
CONTAINER="devcontainer-{{PROJECT_NAME}}"
# 先取得清單再比對，避免 pipefail 下 grep 提早結束造成誤判
if ! grep -qx "${CONTAINER}" <<< "$(docker ps --format '{{.Names}}')"; then
    echo "Container not running. Run ./scripts/start.sh first."
    exit 1
fi

CONFIG_FILE="${PROJECT_DIR}/project-config.json"

# 容器使用者（預設 node，可在 project-config.json 中覆寫）
CONTAINER_USER="node"
AGENT="claude"
if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
    _user=$(jq -r '.container_user // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$_user" ] && CONTAINER_USER="$_user"
    _agent=$(jq -r '.agent // "claude"' "$CONFIG_FILE" 2>/dev/null || echo "claude")
    [ -n "$_agent" ] && AGENT="$_agent"
fi

# 只接受一般的非 root 使用者名稱（與 start.sh 相同規則）
if [[ ! "$CONTAINER_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$CONTAINER_USER" = "root" ]; then
    echo "Error: project-config.json 的 container_user 不合法（需為非 root 的 Linux 使用者名稱，例如 node）"
    exit 1
fi

# 防火牆規則存在於容器的 network namespace：容器若不是由 start.sh 啟動（例如直接 docker start/restart），規則就不存在
if [ ! -f "${REPO_DIR}/lib/helpers.sh" ]; then
    echo "Error: ${REPO_DIR}/lib/helpers.sh not found. Was the claude-dev-workflow repo moved or deleted?"
    exit 1
fi
# shellcheck source=/dev/null
source "${REPO_DIR}/lib/helpers.sh"
if ! cdw_apply_firewall "${CONTAINER}" "" --check >/dev/null 2>&1; then
    echo "Error: the firewall is not active in ${CONTAINER} (the container was probably restarted without ./scripts/start.sh)."
    echo "Run ./scripts/start.sh to recreate it with the firewall."
    exit 1
fi

if [ "$AGENT" = "codex" ]; then
    echo "Entering container. Run 'codex' to start developing."
    if [ ! -f "${PROJECT_DIR}/codex-data/auth.json" ]; then
        echo "（首次使用：在容器內執行 'codex login --device-auth'，需先在 ChatGPT 安全設定中啟用裝置碼登入；"
        echo "  或把已登入電腦上的 ~/.codex/auth.json 複製到 ${PROJECT_DIR}/codex-data/auth.json）"
    fi
else
    echo "Entering container. Run 'claude --dangerously-skip-permissions' to start developing."
fi
docker exec -it -u "${CONTAINER_USER}" -w /workspace "${CONTAINER}" /bin/bash --login
