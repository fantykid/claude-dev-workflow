FROM node:20

# 基礎工具（防火牆由 host 建置的 claude-dev-firewall image 從外部套用，開發 image 不含防火牆工具）
# iproute2 與 curl 為 start.sh 所需（取得 host IP、MCP 健康檢查）
RUN apt-get update && apt-get install -y --no-install-recommends \
    less git procps fzf zsh man-db gnupg2 gh \
    iproute2 dnsutils jq \
    nano vim curl tmux \
    && rm -rf /var/lib/apt/lists/*

# === Bootstrap 會根據專案需求在此加入語言/框架套件 ===
# {{ADDITIONAL_PACKAGES}}

# npm global 路徑（對齊官方）
RUN mkdir -p /usr/local/share/npm-global/lib && \
    chown -R node:node /usr/local/share/npm-global

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV DEVCONTAINER=true

# 建立工作目錄和 agent config 目錄（.claude 供 Claude Code；.codex 供 Codex）
RUN mkdir -p /workspace /home/node/.claude /home/node/.codex && \
    chown -R node:node /workspace /home/node/.claude /home/node/.codex

# tmux 預設設定（滑鼠支援 + 基本配置）
RUN echo 'set -g mouse on' > /home/node/.tmux.conf && \
    chown node:node /home/node/.tmux.conf

USER node

# === Bootstrap 會根據是否啟用 gstack 在此加入 Bun + Playwright ===
# {{GSTACK_DEPS}}

# ── 以下每次 build 都重新執行（拉最新版）──
ARG CACHEBUST_TOOLS=0

# === Agent 安裝：Bootstrap 依 project-config.json 的 agent 欄位填入此處 ===
# {{AGENT_INSTALL}}

# === Bootstrap 會根據是否啟用 gstack 在此加入 gstack 安裝 ===
# {{GSTACK_INSTALL}}

WORKDIR /workspace
CMD ["/bin/bash"]
