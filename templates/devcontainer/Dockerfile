FROM node:22-bookworm

# 基礎工具（防火牆由 host 建置的 claude-dev-firewall image 從外部套用，開發 image 不含防火牆工具）
# iproute2 與 curl 為 start.sh 所需（取得 host IP、MCP 健康檢查）
RUN apt-get update && apt-get install -y --no-install-recommends \
    less git procps fzf zsh man-db gnupg2 \
    iproute2 dnsutils jq \
    nano vim curl tmux ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI：依官方安裝文件改用 GitHub 的 apt 套件庫（Debian 社群版本過舊，官方文件指出已因 GitHub API 淘汰而損壞）
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# === Bootstrap 會根據專案需求在此加入語言/框架套件 ===
# {{ADDITIONAL_PACKAGES}}

# npm global 路徑（對齊官方）
RUN mkdir -p /usr/local/share/npm-global/lib && \
    chown -R node:node /usr/local/share/npm-global

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV DEVCONTAINER=true
# enter.sh 以 login shell 進入容器，而 Debian 的 /etc/profile 會重設 PATH，npm 全域目錄（claude、codex 所在）因此消失
RUN echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' > /etc/profile.d/npm-global.sh
# node-gyp 編譯原生模組時使用 image 內建的 Node headers，不必從 nodejs.org 下載（防火牆未放行該網域）
ENV npm_config_nodedir=/usr/local

# 建立工作目錄和 agent config 目錄（.claude 供 Claude Code；.codex 供 Codex）
RUN mkdir -p /workspace /home/node/.claude /home/node/.codex && \
    chown -R node:node /workspace /home/node/.claude /home/node/.codex

# tmux 預設設定（滑鼠支援 + 基本配置）
RUN echo 'set -g mouse on' > /home/node/.tmux.conf && \
    chown node:node /home/node/.tmux.conf

USER node

# ── 以下每次 build 都重新執行（拉最新版）──
ARG CACHEBUST_TOOLS=0

# === AGENT_INSTALL BEGIN ===
# 預設安裝 Claude Code；agent 為 codex 時，Bootstrap 會把 BEGIN 與 END 之間替換為 Codex 安裝
# 最低版本要求：v2.1.83（auto-memory 的 MEMORY.md 25KB 上限）、v2.0.64（.claude/rules/）
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && INSTALLED_VER=$(claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) \
    && echo "Installed Claude Code: ${INSTALLED_VER}" \
    && node -e "const v=process.argv[1].split('.').map(Number); const min=[2,1,83]; const ok = v[0]>min[0] || (v[0]===min[0] && (v[1]>min[1] || (v[1]===min[1] && v[2]>=min[2]))); if(!ok){console.error('ERROR: Claude Code '+process.argv[1]+' < 2.1.83');process.exit(1)}" "${INSTALLED_VER}"
# === AGENT_INSTALL END ===

WORKDIR /workspace
CMD ["/bin/bash"]
