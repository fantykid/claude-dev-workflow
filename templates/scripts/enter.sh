#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="{{PROJECT_DIR}}"
CONTAINER="devcontainer-{{PROJECT_NAME}}"
if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo "Container not running. Run ./scripts/start.sh first."
    exit 1
fi

# 容器使用者（預設 node，可在 project-config.json 中覆寫）
CONTAINER_USER="node"
CONFIG_FILE="${PROJECT_DIR}/project-config.json"
if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
    _user=$(jq -r '.container_user // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$_user" ] && CONTAINER_USER="$_user"
fi

echo "Entering container. Run 'claude --dangerously-skip-permissions' to start developing."
docker exec -it -u "${CONTAINER_USER}" -w /workspace "${CONTAINER}" /bin/bash --login
