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
