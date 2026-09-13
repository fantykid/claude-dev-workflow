#!/usr/bin/env bash
set -euo pipefail
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_DIR="{{PROJECT_DIR}}"
REPO_DIR="{{REPO_DIR}}"
CONTAINER="devcontainer-${PROJECT_NAME}"
CONFIG_FILE="${PROJECT_DIR}/project-config.json"

# 重新套用防火牆白名單到執行中的容器：不重啟容器、不中斷容器內的程式
# 使用時機：修改 project-config.json 的 extra_allowed_domains 之後，或長時間運行後網域 IP 變動導致連線異常時

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed on host machine"
    exit 1
fi
if [ ! -f "${REPO_DIR}/lib/helpers.sh" ]; then
    echo "Error: ${REPO_DIR}/lib/helpers.sh not found. Was the claude-dev-workflow repo moved or deleted?"
    exit 1
fi
# shellcheck source=/dev/null
source "${REPO_DIR}/lib/helpers.sh"

if ! grep -qx "${CONTAINER}" <<< "$(docker ps --format '{{.Names}}')"; then
    echo "Container not running. Run ./scripts/start.sh first."
    exit 1
fi

if ! EXTRA_DOMAINS=$(cdw_extra_allowed_domains "$CONFIG_FILE"); then
    exit 1
fi
if ! ensure_firewall_image "${REPO_DIR}/templates"; then
    exit 1
fi

echo "Refreshing firewall allowlist for ${CONTAINER}..."
if ! cdw_apply_firewall "${CONTAINER}" "${EXTRA_DOMAINS}" --refresh; then
    echo "ERROR: Firewall refresh failed; the previous allowlist is still in effect."
    exit 1
fi
echo "✓ Firewall allowlist refreshed${EXTRA_DOMAINS:+ (extra: ${EXTRA_DOMAINS})}"
