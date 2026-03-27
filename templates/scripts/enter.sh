#!/usr/bin/env bash
set -euo pipefail
CONTAINER="devcontainer-{{PROJECT_NAME}}"
if ! docker ps -q -f "name=${CONTAINER}" | grep -q .; then
    echo "Container not running. Run ./scripts/start.sh first."
    exit 1
fi
echo "Entering container. Run 'claude --dangerously-skip-permissions' to start developing."
docker exec -it -u node -w /workspace "${CONTAINER}" /bin/bash
