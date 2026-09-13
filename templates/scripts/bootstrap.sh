#!/usr/bin/env bash
set -euo pipefail
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_DIR="{{PROJECT_DIR}}"
REPO_DIR="{{REPO_DIR}}"

# 確認 OAuth token 存在
TOKEN_FILE="${HOME}/.claude/.oauth-token"
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
if [ ! -s "$TOKEN_FILE" ]; then
    echo "WARNING: $TOKEN_FILE is empty; Bootstrap Claude Code will ask you to /login (the login is kept in .bootstrap-claude/)"
fi

# 確認 Bootstrap memory 目錄存在
if [ ! -d "${PROJECT_DIR}/.bootstrap-claude" ]; then
    echo "Error: .bootstrap-claude/ not found. Was this project created with init.sh?"
    exit 1
fi

# 確認 repo 目錄存在（模板與 host 端共用函式）
if [ ! -d "${REPO_DIR}/templates" ] || [ ! -f "${REPO_DIR}/lib/helpers.sh" ]; then
    echo "Error: claude-dev-workflow not found at ${REPO_DIR} (templates/ or lib/helpers.sh missing)"
    echo "Was the claude-dev-workflow repo moved, deleted, or checked out at an older version?"
    exit 1
fi
# shellcheck source=/dev/null
source "${REPO_DIR}/lib/helpers.sh"

# 確保 Bootstrap image 是最新的（Claude Code 版本、權限政策）
if ! ensure_bootstrap_image "${REPO_DIR}/templates"; then
    exit 1
fi

echo "Launching Bootstrap Claude Code for: ${PROJECT_NAME}"
echo "Bootstrap has access to its previous memory and decisions."
echo "================================================"
echo ""

# 重新啟動 Bootstrap 容器（安全設計見 init.sh 的說明）
# 隱藏 Bootstrap 用不到、但含有憑證或私人資料的目錄；只遮蔽已存在的目錄，避免 Docker 以 root 在 host 建立空目錄
# .bootstrap-claude/ 只從 /workspace 遮蔽（/login 的憑證存在裡面）；Claude Code 仍透過 /home/node/.claude 使用它
MASK_ARGS=()
for dir in secrets claude-data codex-data gstack-data .bootstrap-claude; do
    if [ -d "${PROJECT_DIR}/${dir}" ]; then
        MASK_ARGS+=(--mount "type=tmpfs,destination=/workspace/${dir},tmpfs-size=1m,tmpfs-mode=0500")
    fi
done

docker rm -f "bootstrap-${PROJECT_NAME}" 2>/dev/null || true
docker run -it --rm \
    --name "bootstrap-${PROJECT_NAME}" \
    --hostname "bootstrap" \
    --cap-drop=ALL \
    --security-opt no-new-privileges \
    -e "PROJECT_NAME=${PROJECT_NAME}" \
    -e "HOST_PROJECT_DIR=${PROJECT_DIR}" \
    -v "${TOKEN_FILE}:/run/secrets/claude-oauth-token:ro" \
    -v "${PROJECT_DIR}:/workspace" \
    -v "${PROJECT_DIR}/.bootstrap-claude:/home/node/.claude" \
    -v "${PROJECT_DIR}/scripts:/workspace/scripts:ro" \
    -v "${REPO_DIR}/templates:/workspace/templates:ro" \
    -v "${PROJECT_DIR}/.claude:/workspace/.claude:ro" \
    -v "${PROJECT_DIR}/.claude/settings.json:/home/node/.claude/settings.json:ro" \
    ${MASK_ARGS[@]+"${MASK_ARGS[@]}"} \
    -w /workspace \
    "$BOOTSTRAP_IMAGE"

echo ""
echo "================================================"
echo "✓ Bootstrap session ended"
