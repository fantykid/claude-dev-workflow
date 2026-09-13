#!/usr/bin/env bash
# claude-dev-workflow 的 host 端共用函式
# 由 init.sh 與產生出來的 scripts/*.sh 以 source 載入；只在 host 上執行，不會放進任何容器

FIREWALL_IMAGE="claude-dev-firewall:latest"
CDW_LABEL_CONTEXT="claude-dev-workflow.context-sha256"

# 目錄內所有檔案（含相對路徑）的雜湊，用來判斷 image 是否需要重建；沒有雜湊工具時輸出空字串
cdw_dir_hash() {
    local dir="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        (cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
    fi
}

# 讀取 image 的 label；image 或 label 不存在時輸出空字串
cdw_image_label() {
    local value
    value=$(docker image inspect --format "{{ index .Config.Labels \"$2\" }}" "$1" 2>/dev/null) || value=""
    if [ "$value" = "<no value>" ]; then
        value=""
    fi
    printf '%s' "$value"
}

# 確保防火牆 image 存在，且與 templates/firewall/ 的內容一致
# 重建失敗但已有舊 image 時沿用舊 image（仍是 host 建置的防火牆）；完全沒有 image 時回傳 1，呼叫端必須中止
ensure_firewall_image() {
    local context="$1/firewall" hash current
    if [ ! -f "${context}/Dockerfile" ]; then
        echo "Error: firewall image context not found: ${context}" >&2
        return 1
    fi
    hash=$(cdw_dir_hash "$context") || hash=""
    if docker image inspect "$FIREWALL_IMAGE" >/dev/null 2>&1; then
        current=$(cdw_image_label "$FIREWALL_IMAGE" "$CDW_LABEL_CONTEXT")
        if [ -n "$hash" ] && [ "$hash" = "$current" ]; then
            return 0
        fi
        echo "Updating firewall image (${FIREWALL_IMAGE})..."
        if ! docker build --label "${CDW_LABEL_CONTEXT}=${hash}" -t "$FIREWALL_IMAGE" "$context"; then
            echo "WARNING: failed to rebuild ${FIREWALL_IMAGE}; using the existing image" >&2
        fi
        return 0
    fi
    echo "Building firewall image (${FIREWALL_IMAGE})..."
    if ! docker build --label "${CDW_LABEL_CONTEXT}=${hash}" -t "$FIREWALL_IMAGE" "$context"; then
        echo "Error: failed to build ${FIREWALL_IMAGE}" >&2
        return 1
    fi
}

# 讀出 project-config.json 的 extra_allowed_domains（字串陣列），驗證後以空白分隔輸出
# 格式不合法時回傳 1（防火牆腳本也會再驗證一次）
cdw_extra_allowed_domains() {
    local config="$1" raw d count=0
    local -a domains=()
    [ -f "$config" ] || return 0
    if ! jq -e '(.extra_allowed_domains // []) | type == "array" and all(.[]; type == "string")' "$config" >/dev/null 2>&1; then
        echo "Error: project-config.json 的 extra_allowed_domains 必須是字串陣列" >&2
        return 1
    fi
    raw=$(jq -r '(.extra_allowed_domains // [])[]' "$config" | tr '[:upper:]' '[:lower:]') || return 1
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [[ ! "$d" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
            echo "Error: extra_allowed_domains 含不合法的網域：${d}" >&2
            return 1
        fi
        count=$((count + 1))
        if [ "$count" -gt 50 ]; then
            echo "Error: extra_allowed_domains 最多 50 個網域" >&2
            return 1
        fi
        domains+=("$d")
    done <<< "$raw"
    local IFS=' '
    printf '%s' "${domains[*]}"
}

# 以一次性容器（共用開發容器的 network namespace）套用防火牆；額外參數 --refresh 表示只刷新白名單
cdw_apply_firewall() {
    local container="$1" extra_domains="$2"
    shift 2
    docker run --rm \
        --user root \
        --cap-drop=ALL \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --network "container:${container}" \
        -e "EXTRA_ALLOWED_DOMAINS=${extra_domains}" \
        "$FIREWALL_IMAGE" "$@"
}

BOOTSTRAP_IMAGE="bootstrap-claude:latest"
CDW_LABEL_CLAUDE_VERSION="claude-dev-workflow.claude-code-version"

# 查詢 npm 上 Claude Code 的版本號（BOOTSTRAP_CLAUDE_CHANNEL=latest|stable，預設 latest）；查不到時輸出空字串
cdw_claude_code_version() {
    local channel="${BOOTSTRAP_CLAUDE_CHANNEL:-latest}" version=""
    if [ "$channel" != "latest" ] && [ "$channel" != "stable" ]; then
        echo "WARNING: BOOTSTRAP_CLAUDE_CHANNEL must be latest or stable; using latest" >&2
        channel="latest"
    fi
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        version=$(curl -fsS --max-time 10 "https://registry.npmjs.org/@anthropic-ai/claude-code/${channel}" 2>/dev/null \
            | jq -r '.version // empty' 2>/dev/null) || version=""
    fi
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$version"
    fi
}

# 確保 Bootstrap image 使用最新的 Claude Code，且包含目前 templates/bootstrap/ 的權限政策
# BOOTSTRAP_AUTO_UPDATE=0 跳過更新檢查；BOOTSTRAP_CLAUDE_CHANNEL=stable 改追 stable 通道
# 只有在沒有可用的新式 image 時回傳 1（舊式 image 沒有 managed settings，不能沿用）
ensure_bootstrap_image() {
    local context="$1/bootstrap" image="${2:-$BOOTSTRAP_IMAGE}"
    local hash target current_hash="" current_version="" old_id="" new_id has_image=false usable=false
    if [ ! -f "${context}/Dockerfile" ]; then
        echo "Error: Bootstrap image context not found: ${context}" >&2
        return 1
    fi
    hash=$(cdw_dir_hash "$context") || hash=""

    if docker image inspect "$image" >/dev/null 2>&1; then
        has_image=true
        old_id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null) || old_id=""
        current_hash=$(cdw_image_label "$image" "$CDW_LABEL_CONTEXT")
        current_version=$(cdw_image_label "$image" "$CDW_LABEL_CLAUDE_VERSION")
        # 有 context label 的才是含權限政策的新式 image
        if [ -n "$current_hash" ]; then
            usable=true
        fi
    fi

    if [ "$usable" = true ] && [ "${BOOTSTRAP_AUTO_UPDATE:-1}" = "0" ]; then
        return 0
    fi

    target=$(cdw_claude_code_version)
    if [ -z "$target" ]; then
        if [ "$usable" = true ]; then
            echo "WARNING: 無法查詢 Claude Code 最新版本（npm registry 無法連線），沿用現有 Bootstrap image（Claude Code ${current_version:-unknown}）" >&2
            return 0
        fi
        echo "WARNING: 無法查詢 Claude Code 最新版本，改以 latest 建置 Bootstrap image" >&2
    fi

    if [ "$usable" = true ] && [ -n "$target" ] && [ "$target" = "$current_version" ] \
        && [ -n "$hash" ] && [ "$hash" = "$current_hash" ]; then
        echo "Bootstrap Claude Code: ${current_version} (up to date)"
        return 0
    fi

    if [ "$has_image" = true ]; then
        echo "Updating Bootstrap image: Claude Code ${current_version:-unknown} -> ${target:-latest}"
    else
        echo "Building Bootstrap image: Claude Code ${target:-latest}"
    fi
    local build_args=(--build-arg "CLAUDE_CODE_VERSION=${target:-latest}"
        --label "${CDW_LABEL_CONTEXT}=${hash}"
        --label "${CDW_LABEL_CLAUDE_VERSION}=${target}"
        -t "$image" "$context")
    if ! docker build --pull "${build_args[@]}"; then
        echo "WARNING: build with --pull failed; retrying with the cached base image" >&2
        if ! docker build "${build_args[@]}"; then
            if [ "$usable" = true ]; then
                echo "WARNING: 無法更新 Bootstrap image，沿用現有版本（Claude Code ${current_version:-unknown}）" >&2
                return 0
            fi
            echo "Error: failed to build ${image}" >&2
            if [ "$has_image" = true ]; then
                echo "The existing ${image} predates the Bootstrap security policy and will not be used." >&2
            fi
            return 1
        fi
    fi

    new_id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null) || new_id=""
    if [ -n "$old_id" ] && [ "$old_id" != "$new_id" ]; then
        # 被執行中的容器使用或有其他 tag 時會刪不掉，忽略即可
        docker image rm "$old_id" >/dev/null 2>&1 || true
    fi
    echo "✓ Bootstrap Claude Code: ${target:-latest}"
}

# 直接執行時手動更新 image，例如：./lib/helpers.sh bootstrap（讓舊專案的 bootstrap.sh 也用上新版）
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    CDW_TEMPLATES="$(cd "$(dirname "$0")/.." && pwd)/templates"
    case "${1:-}" in
        bootstrap) ensure_bootstrap_image "$CDW_TEMPLATES" ;;
        firewall) ensure_firewall_image "$CDW_TEMPLATES" ;;
        *) echo "Usage: $0 bootstrap|firewall"; exit 1 ;;
    esac
fi
