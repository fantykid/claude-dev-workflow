#!/usr/bin/env bash
set -euo pipefail
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_DIR="{{PROJECT_DIR}}"
docker build \
    -t "devcontainer-${PROJECT_NAME}:latest" \
    -f "${PROJECT_DIR}/repo/.devcontainer/Dockerfile" \
    "${PROJECT_DIR}/repo/.devcontainer"
echo "✓ Image built: devcontainer-${PROJECT_NAME}:latest"
