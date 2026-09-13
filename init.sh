#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${1:?Usage: ./init.sh <project-name>}"
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_SRC="${BASE_DIR}/templates"
PROJECT_DIR="$(dirname "$BASE_DIR")/${PROJECT_NAME}"

# 驗證名稱格式（小寫字母、數字、連字號）
if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "Error: project name must be lowercase alphanumeric with hyphens"
    echo "Example: my-web-app, api-server, ml-experiment1"
    exit 1
fi

# 防止覆蓋現有專案
if [ -d "$PROJECT_DIR" ]; then
    echo "Error: $PROJECT_DIR already exists"
    exit 1
fi

# 防止與 repo 本身同名
if [ "$PROJECT_DIR" = "$BASE_DIR" ]; then
    echo "Error: project name conflicts with this tool's directory"
    exit 1
fi

# 確認模板與 host 端共用函式存在
if [ ! -d "$TEMPLATE_SRC" ] || [ ! -f "${BASE_DIR}/lib/helpers.sh" ]; then
    echo "Error: templates/ or lib/helpers.sh not found in ${BASE_DIR}"
    echo "Make sure init.sh is run from a complete claude-dev-workflow checkout."
    exit 1
fi
# shellcheck source=/dev/null
source "${BASE_DIR}/lib/helpers.sh"

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

# ============================================================
# 確保 Bootstrap image 是最新的（Claude Code 版本、權限政策）
# 在建立專案目錄之前完成，失敗時不會留下只建一半的專案
# ============================================================
if ! ensure_bootstrap_image "$TEMPLATE_SRC"; then
    exit 1
fi

echo ""
echo "Creating project: ${PROJECT_NAME}"
echo "Location: ${PROJECT_DIR}"
echo ""

# ============================================================
# 建立目錄結構
# ============================================================
mkdir -p "$PROJECT_DIR"
mkdir -p -m 700 "$PROJECT_DIR/.bootstrap-claude" # Bootstrap 的 Claude 記憶與狀態（持久化用；/login 後也存放登入憑證）
mkdir -p "$PROJECT_DIR/.claude"                  # Bootstrap 的備援權限設定（容器內唯讀）
mkdir -p "$PROJECT_DIR/scripts"                  # Host 管理腳本
mkdir -p "$PROJECT_DIR/data"                     # 持久資料
mkdir -p -m 700 "$PROJECT_DIR/secrets"           # 憑證（使用者自行管理）
mkdir -p -m 700 "$PROJECT_DIR/claude-data"       # Claude Code session + 登入狀態（必備）

# ============================================================
# 複製 Bootstrap 設定
# ============================================================

# Bootstrap 角色指引
cp "${TEMPLATE_SRC}/bootstrap/CLAUDE.md" "$PROJECT_DIR/"

# 備援權限設定：實際強制的是 Bootstrap image 內的 managed settings（/init-project 也內建在 image 中）
cp "${TEMPLATE_SRC}/bootstrap/claude-config/settings.json" "$PROJECT_DIR/.claude/"

# ============================================================
# 在 HOST 上從模板產生管理腳本（安全關鍵：Bootstrap 無法修改）
# ============================================================
echo "Generating management scripts..."
for script in build.sh start.sh enter.sh stop.sh bootstrap.sh firewall.sh; do
    sed -e "s|{{PROJECT_NAME}}|${PROJECT_NAME}|g" \
        -e "s|{{PROJECT_DIR}}|${PROJECT_DIR}|g" \
        -e "s|{{REPO_DIR}}|${BASE_DIR}|g" \
        "${TEMPLATE_SRC}/scripts/${script}" > "${PROJECT_DIR}/scripts/${script}"
done
chmod +x "${PROJECT_DIR}/scripts/"*.sh

echo "✓ Project directory created"
echo "✓ Management scripts generated on host"
echo ""

echo "Launching Bootstrap Claude Code in container..."
echo "================================================"
echo ""

# ============================================================
# 啟動 Bootstrap 容器
# ============================================================
# 安全設計：
# - --cap-drop=ALL、no-new-privileges：Bootstrap 不需要任何特權
# - 權限由 image 內的 managed settings 強制（專案、本機、使用者設定都無法放寬）
# - /workspace = 專案目錄；scripts/、templates/、.claude/ 以 :ro 掛載
# - secrets/、claude-data/ 等含憑證的目錄以 tmpfs 遮蔽，Bootstrap 看不到內容
#   （只遮蔽已存在的目錄，避免 Docker 以 root 在 host 建立空目錄）
# - .bootstrap-claude/ 也從 /workspace 遮蔽（/login 的憑證存在裡面）；Claude Code 仍透過 /home/node/.claude 使用它
# - OAuth token 以唯讀檔案掛載，由 image 的 entrypoint 載入（不出現在 docker inspect）
# - /home/node/.claude = Bootstrap 記憶持久化
# - PROJECT_NAME 和 HOST_PROJECT_DIR 透過環境變數傳入
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
    -v "${TEMPLATE_SRC}:/workspace/templates:ro" \
    -v "${PROJECT_DIR}/.claude:/workspace/.claude:ro" \
    -v "${PROJECT_DIR}/.claude/settings.json:/home/node/.claude/settings.json:ro" \
    ${MASK_ARGS[@]+"${MASK_ARGS[@]}"} \
    -w /workspace \
    "$BOOTSTRAP_IMAGE"

echo ""
echo "================================================"
echo "✓ Bootstrap session ended"

echo ""
echo "Next steps:"
echo "  1. cd ${PROJECT_DIR}"
echo "  2. ./scripts/build.sh   (build dev container image)"
echo "  3. ./scripts/start.sh   (start container)"
echo "  4. ./scripts/enter.sh   (enter container)"
echo "  5. claude --dangerously-skip-permissions   (or: codex, if agent is codex)"
echo ""
echo "To re-enter Bootstrap later: ./scripts/bootstrap.sh"
echo "If a domain is blocked by the firewall: add it to extra_allowed_domains in project-config.json, then run ./scripts/firewall.sh"
