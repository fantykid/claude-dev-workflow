#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="{{PROJECT_DIR}}"
CONTAINER="devcontainer-{{PROJECT_NAME}}"
if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
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

if [ "$AGENT" = "codex" ]; then
    echo "Entering container. Run 'codex' to start developing."
    if [ ! -f "${PROJECT_DIR}/codex-data/auth.json" ]; then
        echo "（首次使用先在容器內執行 'codex login' 完成登入；登入狀態會持久化於 codex-data）"
    fi
else
    echo "Entering container. Run 'claude --dangerously-skip-permissions' to start developing."
fi
docker exec -it -u "${CONTAINER_USER}" -w /workspace "${CONTAINER}" /bin/bash --login
