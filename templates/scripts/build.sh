#!/usr/bin/env bash
set -euo pipefail
PROJECT_NAME="{{PROJECT_NAME}}"
PROJECT_DIR="{{PROJECT_DIR}}"
CONTEXT="${PROJECT_DIR}/repo/.devcontainer"
# 上次成功建置的內容，以及這次要審視並建置的複本（都在 repo/ 之外，開發容器看不到也改不到）
REVIEW_DIR="${PROJECT_DIR}/.build-review"
LAST="${REVIEW_DIR}/last-built"
PENDING="${REVIEW_DIR}/pending"
DIFF_FILE="${REVIEW_DIR}/pending.diff"

ASSUME_YES=false
case "${1:-}" in
    "") ;;
    -y|--yes) ASSUME_YES=true ;;
    *) echo "Usage: ./scripts/build.sh [--yes]"; exit 1 ;;
esac

# symlink 會讓 docker build 讀到 repo/ 以外的 host 檔案，一律拒絕
if [ -L "$CONTEXT" ] || [ -L "${CONTEXT}/Dockerfile" ]; then
    echo "Error: repo/.devcontainer and its Dockerfile must not be symlinks."
    exit 1
fi
if [ ! -f "${CONTEXT}/Dockerfile" ]; then
    echo "Error: ${CONTEXT}/Dockerfile not found. Run ./scripts/bootstrap.sh to generate it."
    exit 1
fi

# 開發代理可以修改 repo/.devcontainer/，而建置時網路完全開放，所以建置前要讓使用者看過改動。
# 先複製一份再比對與建置：審視的內容就是實際建置的內容，建置途中 repo/ 被改動也不影響
mkdir -p "$REVIEW_DIR"
rm -rf "$PENDING"
cp -RP "$CONTEXT" "$PENDING"

# 不追蹤 symlink：避免讀出或印出 host 上 symlink 指向的檔案
DIFF_OPTS=(-ruN)
if diff --no-dereference /dev/null /dev/null >/dev/null 2>&1; then
    DIFF_OPTS+=(--no-dereference)
fi

if [ -d "$LAST" ] && ! (cd "$REVIEW_DIR" && diff "${DIFF_OPTS[@]}" last-built pending >/dev/null 2>&1); then
    # 刪除控制字元，避免檔案內容裡的跳脫序列操控終端機
    (cd "$REVIEW_DIR" && diff "${DIFF_OPTS[@]}" last-built pending || true) | LC_ALL=C tr -d '\000-\010\013-\037\177' > "$DIFF_FILE"
    LINES=$(wc -l < "$DIFF_FILE" | tr -d ' ')
    echo "repo/.devcontainer/ changed since the last successful build (${LINES} diff lines):"
    echo "------------------------------------------------------------"
    head -n 200 "$DIFF_FILE"
    if [ "$LINES" -gt 200 ]; then
        echo "... (first 200 lines shown; full diff: ${DIFF_FILE})"
    fi
    echo "------------------------------------------------------------"
    echo "The project agent can edit these files, and the build runs with full network access."
    if [ "$ASSUME_YES" != true ]; then
        if [ ! -t 0 ]; then
            echo "Review the changes above, then run ./scripts/build.sh --yes to build them."
            exit 1
        fi
        read -r -p "Build with these changes? [y/N] " answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) echo "Build cancelled."; exit 1 ;;
        esac
    fi
fi

docker build \
    --build-arg CACHEBUST_TOOLS=$(date +%s) \
    -t "devcontainer-${PROJECT_NAME}:latest" \
    -f "${PENDING}/Dockerfile" \
    "${PENDING}"

rm -rf "$LAST"
mv "$PENDING" "$LAST"
rm -f "$DIFF_FILE"
echo "✓ Image built: devcontainer-${PROJECT_NAME}:latest"
