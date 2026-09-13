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

# 是否為 RFC 1918 私有位址範圍內的 IPv4 CIDR（例如 Docker network 的網段）；templates/firewall/init-firewall.sh 用相同規則再驗證一次
cdw_is_private_ipv4_cidr() {
    local cidr="$1" a b len octet
    [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        [ "$((10#$octet))" -le 255 ] || return 1
    done
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); len=$((10#${BASH_REMATCH[5]}))
    [ "$len" -le 32 ] || return 1
    if [ "$a" -eq 10 ] && [ "$len" -ge 8 ]; then return 0; fi
    if [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && [ "$len" -ge 12 ]; then return 0; fi
    if [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && [ "$len" -ge 16 ]; then return 0; fi
    return 1
}

# 選用的筆記 MCP：私人 MCP server 跑在 host 的某個 Docker network 上時，start.sh 自動把開發容器接上
# 設定只放在 host、repo 之外：${XDG_CONFIG_HOME:-~/.config}/claude-dev-workflow/notes-mcp.json
#   {"url": "http://notes-mcp:8080/mcp", "network": "notes-net", "token_file": "~/.config/claude-dev-workflow/notes-token", "server_name": "notes"}
# 讀取並驗證後設定 NOTES_URL、NOTES_NETWORK、NOTES_TOKEN_FILE、NOTES_SERVER_NAME
# 回傳 0：已設定；1：沒有設定檔；2：設定檔不合法（已印出原因）
cdw_notes_mcp_config() {
    local file="${XDG_CONFIG_HOME:-${HOME}/.config}/claude-dev-workflow/notes-mcp.json"
    NOTES_URL="" NOTES_NETWORK="" NOTES_TOKEN_FILE="" NOTES_SERVER_NAME=""
    [ -f "$file" ] || return 1
    if ! jq -e 'type == "object" and (.url | type == "string") and (.network | type == "string")
            and (.token_file | type == "string") and ((.server_name // "notes") | type == "string")' "$file" >/dev/null 2>&1; then
        echo "WARNING: ${file} 需要 url、network、token_file 三個字串欄位（server_name 選填），跳過筆記 MCP" >&2
        return 2
    fi
    NOTES_URL=$(jq -r '.url' "$file")
    NOTES_NETWORK=$(jq -r '.network' "$file")
    NOTES_TOKEN_FILE=$(jq -r '.token_file' "$file")
    NOTES_SERVER_NAME=$(jq -r '.server_name // "notes"' "$file")
    case "$NOTES_TOKEN_FILE" in
        "~/"*) NOTES_TOKEN_FILE="${HOME}/${NOTES_TOKEN_FILE#"~/"}" ;;
    esac
    # 這些值會寫進容器內的設定檔與指令，只接受單純的格式
    if [[ ! "$NOTES_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
        echo "WARNING: ${file} 的 url 格式不支援（只接受 http(s)://主機[:port][/路徑]），跳過筆記 MCP" >&2
        return 2
    fi
    if [[ ! "$NOTES_NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; then
        echo "WARNING: ${file} 的 network 名稱不合法，跳過筆記 MCP" >&2
        return 2
    fi
    if [[ ! "$NOTES_SERVER_NAME" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
        echo "WARNING: ${file} 的 server_name 只能用英文字母、數字、_、-，跳過筆記 MCP" >&2
        return 2
    fi
    if [[ "$NOTES_TOKEN_FILE" != /* ]]; then
        echo "WARNING: ${file} 的 token_file 必須是絕對路徑或以 ~/ 開頭，跳過筆記 MCP" >&2
        return 2
    fi
    return 0
}

# 輸出 Docker network 的私有 IPv4 網段（以空白分隔，其他網段略過）；network 不存在時回傳 1
cdw_docker_network_private_subnets() {
    local subnets s
    local -a result=()
    subnets=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$1" 2>/dev/null) || return 1
    for s in $subnets; do
        if cdw_is_private_ipv4_cidr "$s"; then
            result+=("$s")
        fi
    done
    local IFS=' '
    printf '%s' "${result[*]}"
}

# 以一次性容器（共用開發容器的 network namespace）套用防火牆
# 額外參數：--refresh 只刷新白名單；--check 只檢查防火牆是否仍在作用中
# CDW_ALLOWED_NETWORKS（選用）：以空白分隔的私有 IPv4 CIDR，完整套用時額外放行（例如筆記 MCP 的 Docker network）
# --pull never：只使用 host 上從 templates/firewall/ 建置的 image，絕不從 registry 拉取同名 image
cdw_apply_firewall() {
    local container="$1" extra_domains="$2"
    shift 2
    docker run --rm --pull never \
        --user root \
        --cap-drop=ALL \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --network "container:${container}" \
        -e "EXTRA_ALLOWED_DOMAINS=${extra_domains}" \
        -e "EXTRA_ALLOWED_NETWORKS=${CDW_ALLOWED_NETWORKS:-}" \
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
        # 只刪除已經沒有任何 tag、也沒有容器使用的舊 image：
        # docker image rm <ID> 會連同 image 上的其他 tag 一起刪掉（使用者自己標記的備份也不例外），所以要先確認
        local old_tags old_users
        old_tags=$(docker image inspect --format '{{len .RepoTags}}' "$old_id" 2>/dev/null) || old_tags=""
        old_users=$(docker ps -a -q --filter "ancestor=${old_id}" 2>/dev/null) || old_users="unknown"
        if [ "$old_tags" = "0" ] && [ -z "$old_users" ]; then
            docker image rm "$old_id" >/dev/null 2>&1 || true
        fi
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
