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

# 確認模板存在
if [ ! -d "$TEMPLATE_SRC" ]; then
    echo "Error: Template directory not found at $TEMPLATE_SRC"
    echo "Make sure templates/ exists in the same directory as init.sh."
    exit 1
fi

# 確認 credentials 存在
CRED_FILE="${HOME}/.claude/.credentials.json"
if [ ! -f "$CRED_FILE" ]; then
    echo "Error: Claude credentials not found at $CRED_FILE"
    echo "Run 'claude login' on host first (or in any claude container)."
    exit 1
fi

echo "Creating project: ${PROJECT_NAME}"
echo "Location: ${PROJECT_DIR}"
echo ""

# ============================================================
# 建立目錄結構
# ============================================================
mkdir -p "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.bootstrap-claude"       # Claude memory（空，持久化用）
mkdir -p "$PROJECT_DIR/.claude/commands"         # Project settings（權限 + 命令）
mkdir -p "$PROJECT_DIR/scripts"                  # Host 管理腳本
mkdir -p "$PROJECT_DIR/data"                     # 持久資料
mkdir -p "$PROJECT_DIR/secrets"                  # 憑證（使用者自行管理）

# ============================================================
# 複製 Bootstrap 設定
# ============================================================

# Bootstrap 角色指引
cp "${TEMPLATE_SRC}/bootstrap/CLAUDE.md" "$PROJECT_DIR/"

# Project settings（settings.json + commands/）→ .claude/（強制生效）
cp "${TEMPLATE_SRC}/bootstrap/claude-config/settings.json" "$PROJECT_DIR/.claude/"
cp -r "${TEMPLATE_SRC}/bootstrap/claude-config/commands/." "$PROJECT_DIR/.claude/commands/"

# ============================================================
# 在 HOST 上從模板產生管理腳本（安全關鍵：Bootstrap 無法修改）
# ============================================================
echo "Generating management scripts..."
for script in build.sh start.sh enter.sh stop.sh bootstrap.sh; do
    sed -e "s|{{PROJECT_NAME}}|${PROJECT_NAME}|g" \
        -e "s|{{PROJECT_DIR}}|${PROJECT_DIR}|g" \
        -e "s|{{REPO_DIR}}|${BASE_DIR}|g" \
        "${TEMPLATE_SRC}/scripts/${script}" > "${PROJECT_DIR}/scripts/${script}"
done
chmod +x "${PROJECT_DIR}/scripts/"*.sh

echo "✓ Project directory created"
echo "✓ Management scripts generated on host"
echo ""
# ============================================================
# 建構 Bootstrap image（首次使用時自動建構）
# ============================================================
BOOTSTRAP_IMAGE="bootstrap-claude:latest"
if ! docker image inspect "$BOOTSTRAP_IMAGE" >/dev/null 2>&1; then
    echo "Building bootstrap image (first time only)..."
    docker build -t "$BOOTSTRAP_IMAGE" "${TEMPLATE_SRC}/bootstrap/"
    echo "✓ Bootstrap image built"
    echo ""
fi

echo "Launching Bootstrap Claude Code in container..."
echo "================================================"
echo ""

# ============================================================
# 啟動 Bootstrap 容器
# ============================================================
# 安全設計：
# - /workspace = 專案目錄（含 .claude/ project settings — 權限強制生效）
# - /home/node/.claude = memory 持久化
# - scripts/ 以 :ro 覆蓋掛載（Bootstrap 無法修改）
# - templates/ 從 repo 掛載為 :ro（不再複製到專案內）
# - settings.json 和 commands/ 以 :ro 個別掛載（保護權限設定，不阻擋 .claude/ 其餘寫入）
# - credentials.json 唯讀掛載
# - PROJECT_NAME 和 HOST_PROJECT_DIR 透過環境變數傳入
docker rm -f "bootstrap-${PROJECT_NAME}" 2>/dev/null || true
docker run -it --rm \
    --name "bootstrap-${PROJECT_NAME}" \
    --hostname "bootstrap" \
    -e "PROJECT_NAME=${PROJECT_NAME}" \
    -e "HOST_PROJECT_DIR=${PROJECT_DIR}" \
    -v "${PROJECT_DIR}:/workspace" \
    -v "${PROJECT_DIR}/.bootstrap-claude:/home/node/.claude" \
    -v "${CRED_FILE}:/home/node/.claude/.credentials.json:ro" \
    -v "${PROJECT_DIR}/scripts:/workspace/scripts:ro" \
    -v "${TEMPLATE_SRC}:/workspace/templates:ro" \
    -v "${PROJECT_DIR}/secrets:/workspace/secrets:ro" \
    -v "${PROJECT_DIR}/.claude/settings.json:/workspace/.claude/settings.json:ro" \
    -v "${PROJECT_DIR}/.claude/settings.json:/home/node/.claude/settings.json:ro" \
    -v "${PROJECT_DIR}/.claude/commands:/workspace/.claude/commands:ro" \
    -w /workspace \
    "$BOOTSTRAP_IMAGE"

echo ""
echo "================================================"
echo "✓ Bootstrap session ended"

# ============================================================
# Port 預檢（提前警告，最終檢查由 start.sh 負責）
# ============================================================
CONFIG_FILE="${PROJECT_DIR}/project-config.json"
if [ -f "$CONFIG_FILE" ]; then
    PORTS=$(tr -d '\n\r\t' < "$CONFIG_FILE" | grep -oP '"ports"\s*:\s*\[\K[^\]]*' 2>/dev/null | tr -d ' "' | tr ',' '\n' || true)
    PORT_CONFLICTS=""
    for port in $PORTS; do
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                PORT_CONFLICTS="${PORT_CONFLICTS}  - Port ${port} is currently in use\n"
            fi
        fi
    done
    if [ -n "$PORT_CONFLICTS" ]; then
        echo ""
        echo "WARNING: Port conflict detected:"
        echo -e "$PORT_CONFLICTS"
        echo "You can edit ${PROJECT_DIR}/project-config.json to change ports"
        echo "or free up the ports before running start.sh."
        echo ""
    fi
fi

echo ""
echo "Next steps:"
echo "  1. cd ${PROJECT_DIR}"
echo "  2. ./scripts/build.sh   (build dev container image)"
echo "  3. ./scripts/start.sh   (start container)"
echo "  4. ./scripts/enter.sh   (enter container)"
echo "  5. claude --dangerously-skip-permissions  (start developing)"
echo ""
echo "To re-enter Bootstrap later: ./scripts/bootstrap.sh"
