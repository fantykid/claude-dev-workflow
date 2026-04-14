#!/usr/bin/env bash
set -euo pipefail
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_DIR="{{PROJECT_DIR}}"
docker build \
    --build-arg CACHEBUST_TOOLS=$(date +%s) \
    -t "devcontainer-${PROJECT_NAME}:latest" \
    -f "${PROJECT_DIR}/repo/.devcontainer/Dockerfile" \
    "${PROJECT_DIR}/repo/.devcontainer"
echo "✓ Image built: devcontainer-${PROJECT_NAME}:latest"
