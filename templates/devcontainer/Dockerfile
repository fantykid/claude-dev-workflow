FROM node:20

ARG CLAUDE_CODE_VERSION=latest

# 基礎工具 + 防火牆工具（對齊官方 devcontainer）
RUN apt-get update && apt-get install -y --no-install-recommends \
    less git procps sudo fzf zsh man-db gnupg2 gh \
    iptables ipset iproute2 dnsutils jq \
    nano vim curl \
    && (apt-get install -y --no-install-recommends aggregate || echo "WARN: aggregate not available") \
    && rm -rf /var/lib/apt/lists/*

# === Bootstrap 會根據專案需求在此加入語言/框架套件 ===
# {{ADDITIONAL_PACKAGES}}

# npm global 路徑（對齊官方）
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share/npm-global

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV DEVCONTAINER=true

# 建立工作目錄和 Claude config 目錄
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

USER node

# 安裝 Claude Code（對齊官方）
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# 安裝 Bun（gstack 依賴）
RUN curl -fsSL https://bun.sh/install | bash

ENV PATH=$PATH:/home/node/.bun/bin

# 安裝 Playwright 系統依賴（Chromium 需要的 shared libraries）
USER root
RUN npx playwright install-deps chromium
USER node

# 安裝 gstack
RUN git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git /home/node/.claude/skills/gstack && \
    cd /home/node/.claude/skills/gstack && \
    ./setup

# 防火牆腳本 + 最小 sudo 權限（對齊官方）
USER root
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
    chmod 0440 /etc/sudoers.d/node-firewall
USER node

WORKDIR /workspace
CMD ["/bin/bash"]
