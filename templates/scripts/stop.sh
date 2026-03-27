#!/usr/bin/env bash
set -euo pipefail
CONTAINER="devcontainer-{{PROJECT_NAME}}"
docker stop "${CONTAINER}" 2>/dev/null && echo "✓ Stopped." || echo "Not running."
