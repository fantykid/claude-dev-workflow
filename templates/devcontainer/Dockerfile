FROM node:20

ARG CLAUDE_CODE_VERSION=latest

# 基礎工具 + 防火牆工具（對齊官方 devcontainer）
RUN apt-get update && apt-get install -y --no-install-recommends \
    less git procps sudo fzf zsh man-db gnupg2 gh \
    iptables ipset iproute2 dnsutils jq \
    nano vim curl tmux \
    && (apt-get install -y --no-install-recommends aggregate || echo "WARN: aggregate not available") \
    && rm -rf /var/lib/apt/lists/*

# === Bootstrap 會根據專案需求在此加入語言/框架套件 ===
# {{ADDITIONAL_PACKAGES}}

# npm global 路徑（對齊官方）
RUN mkdir -p /usr/local/share/npm-global/lib && \
    chown -R node:node /usr/local/share/npm-global

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV DEVCONTAINER=true

# 建立工作目錄和 Claude config 目錄
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

# tmux 預設設定（滑鼠支援 + 基本配置）
RUN echo 'set -g mouse on' > /home/node/.tmux.conf && \
    chown node:node /home/node/.tmux.conf

USER node

# === Bootstrap 會根據是否啟用 gstack 在此加入 Bun + Playwright ===
# {{GSTACK_DEPS}}

# ── 以下每次 build 都重新執行（拉最新版）──
ARG CACHEBUST_TOOLS=0

# 安裝 Claude Code（對齊官方）
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# === Bootstrap 會根據是否啟用 gstack 在此加入 gstack 安裝 ===
# {{GSTACK_INSTALL}}

# 防火牆腳本 + 最小 sudo 權限（對齊官方）
USER root
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
    chmod 0440 /etc/sudoers.d/node-firewall
USER node

WORKDIR /workspace
CMD ["/bin/bash"]
