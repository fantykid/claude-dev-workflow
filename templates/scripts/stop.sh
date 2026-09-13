#!/usr/bin/env bash
set -euo pipefail
CONTAINER="devcontainer-{{PROJECT_NAME}}"
# 停止並移除容器：防火牆規則在容器停止時就消失，留著已停止的容器，
# 之後被 docker start 或 VS Code 直接啟動就會沒有防火牆。
# start.sh 每次都會重建容器，所以容器內未掛載的檔案本來就不會保留。
if docker rm -f "${CONTAINER}" >/dev/null 2>&1; then
    echo "✓ Stopped and removed ${CONTAINER} (./scripts/start.sh recreates it)."
else
    echo "Not running."
fi
