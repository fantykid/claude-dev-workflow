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
    echo "WARNING: Token file permissions are $TOKEN_PERMS (should be 600)"
    echo "Fix with: chmod 600 $TOKEN_FILE"
fi

# 確認 Bootstrap memory 目錄存在
if [ ! -d "${PROJECT_DIR}/.bootstrap-claude" ]; then
    echo "Error: .bootstrap-claude/ not found. Was this project created with init.sh?"
    exit 1
fi

# 確認 repo 目錄存在（模板來源）
if [ ! -d "${REPO_DIR}/templates" ]; then
    echo "Error: Template directory not found at ${REPO_DIR}/templates"
    echo "Was the claude-dev-workflow repo moved or deleted?"
    exit 1
fi

# 確認 Bootstrap image 存在
BOOTSTRAP_IMAGE="bootstrap-claude:latest"
if ! docker image inspect "$BOOTSTRAP_IMAGE" >/dev/null 2>&1; then
    echo "Bootstrap image not found. Building..."
    docker build -t "$BOOTSTRAP_IMAGE" "${REPO_DIR}/templates/bootstrap/"
    echo "✓ Bootstrap image built"
    echo ""
fi

echo "Launching Bootstrap Claude Code for: ${PROJECT_NAME}"
echo "Bootstrap has access to its previous memory and decisions."
echo "================================================"
echo ""

# 重新啟動 Bootstrap 容器
# scripts/ 以 :ro 掛載，Bootstrap 無法修改
# templates/ 從 repo 掛載為 :ro（模板不在專案內）
# settings.json commands/ 以 :ro 個別掛載，保護權限設定
CLAUDE_TOKEN=$(cat "$TOKEN_FILE")
docker rm -f "bootstrap-${PROJECT_NAME}" 2>/dev/null || true
docker run -it --rm \
    --name "bootstrap-${PROJECT_NAME}" \
    --hostname "bootstrap" \
    -e "PROJECT_NAME=${PROJECT_NAME}" \
    -e "HOST_PROJECT_DIR=${PROJECT_DIR}" \
    -e "ANTHROPIC_API_KEY=${CLAUDE_TOKEN}" \
    -v "${PROJECT_DIR}:/workspace" \
    -v "${PROJECT_DIR}/.bootstrap-claude:/home/node/.claude" \
    -v "${PROJECT_DIR}/scripts:/workspace/scripts:ro" \
    -v "${REPO_DIR}/templates:/workspace/templates:ro" \
    -v "${PROJECT_DIR}/secrets:/workspace/secrets:ro" \
    -v "${PROJECT_DIR}/.claude/settings.json:/workspace/.claude/settings.json:ro" \
    -v "${PROJECT_DIR}/.claude/settings.json:/home/node/.claude/settings.json:ro" \
    -v "${PROJECT_DIR}/.claude/commands:/workspace/.claude/commands:ro" \
    -w /workspace \
    "$BOOTSTRAP_IMAGE"

echo ""
echo "================================================"
echo "✓ Bootstrap session ended"
