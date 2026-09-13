#!/bin/sh
# Bootstrap 容器 entrypoint
# OAuth token 由 init.sh / bootstrap.sh 以唯讀檔案掛載到 /run/secrets/claude-oauth-token（不會出現在 docker inspect）
# 相容舊版 bootstrap.sh：已經用 -e 傳入 CLAUDE_CODE_OAUTH_TOKEN 時不覆寫
# token 檔為空時不設定變數，讓 Claude Code 使用 /login 後保存在 ~/.claude 的登入狀態
TOKEN_PATH=/run/secrets/claude-oauth-token
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -e "$TOKEN_PATH" ]; then
    if [ -r "$TOKEN_PATH" ]; then
        token="$(cat "$TOKEN_PATH")"
        if [ -n "$token" ]; then
            CLAUDE_CODE_OAUTH_TOKEN="$token"
            export CLAUDE_CODE_OAUTH_TOKEN
        fi
        unset token
    else
        echo "WARNING: ${TOKEN_PATH} is not readable by $(id -un) (uid $(id -u)); check ~/.claude/.oauth-token ownership on the host" >&2
    fi
fi
exec "$@"
