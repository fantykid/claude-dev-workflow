FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    git jq \
    && rm -rf /var/lib/apt/lists/*

# npm global 路徑（對齊官方）
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share/npm-global

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
# 容器以 --rm 執行，容器內的自動更新在結束時就會遺失；版本改由 host 的 lib/helpers.sh 重建 image 管理
ENV DISABLE_AUTOUPDATER=1
# 讓 .claude.json（信任設定等）存進持久化的 ~/.claude（host 的 .bootstrap-claude/）
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# 建立工作目錄
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

# 權限政策與 /init-project skill：managed settings 由 root 擁有，專案、本機、使用者設定都無法覆寫
# 先建立目錄並設為 755：COPY --chmod 會把同樣的權限套到它自動建立的上層目錄，644 的目錄會讓 node 讀不到政策檔
RUN mkdir -p /etc/claude-code/.claude/skills/init-project && chmod -R 755 /etc/claude-code
COPY --chown=root:root --chmod=644 managed-settings.json /etc/claude-code/managed-settings.json
COPY --chown=root:root --chmod=644 skills/init-project/SKILL.md /etc/claude-code/.claude/skills/init-project/SKILL.md
COPY --chown=root:root --chmod=755 entrypoint.sh /usr/local/bin/bootstrap-entrypoint.sh

USER node

# host 端以 --build-arg 傳入精確版本號；放在這裡，版本變動只會讓 npm 這層快取失效
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/bootstrap-entrypoint.sh"]
CMD ["claude"]
