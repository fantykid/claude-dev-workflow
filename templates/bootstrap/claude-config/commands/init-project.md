初始化當前專案目錄。

使用者已經透過 init.sh 建立了此專案目錄並複製了模板。
你在 Docker 容器中運行，只能操作 /workspace 內的檔案。
現在你需要根據使用者的需求，客製化並建立完整的專案結構。

**重要：scripts/ 已由 host 的 init.sh 產生且為唯讀，你不需要也無法寫入 scripts/。**

## 步驟

### 1. 確認環境
確認當前目錄是 /workspace（專案根目錄），應有 templates/ 和 CLAUDE.md。
用 `echo $PROJECT_NAME` 取得專案名稱（由 init.sh 透過環境變數傳入）。
用 `echo $HOST_PROJECT_DIR` 取得 host 上的專案絕對路徑。

### 2. 詢問使用者

只問一個問題：**「你想做什麼？請描述你的專案想法。」**

使用者會用自然語言描述他們的專案想法（例如：「我想做一個能自動抓取新聞的工具」）。
不要逐項詢問類型、語言、port 等技術細節。

你根據描述**自行判斷**：
- **專案類型**：web app / API / CLI tool / automation / AI-ML / mobile / experimental
- **需要的外部服務**：根據描述推斷（例如「存用戶資料」→ 可能需要 PostgreSQL）
- **Port**：根據專案類型自動分配常見 port（如 web app → 3000，API → 8080）。若不需要暴露 port 則留空。
- **搜尋能力**：若專案可能需要查詢網路資料（技術文件、API 文檔、錯誤排查等），設 `mcp_search` 為 `true`。大多數開發專案建議啟用。
- **gstack**：是否安裝 gstack（提供 Playwright 瀏覽器操控、進階工具等能力）。若專案需要網頁爬蟲、瀏覽器測試、UI 自動化等則啟用。一般 CLI 工具、純 API 等不需要。**主動詢問使用者是否需要 gstack**，簡要說明其用途後讓使用者決定。
- **GPU**：若描述提到 GPU、CUDA、模型訓練、推理、3D 重建、機器學習等，設 `gpu` 為 `true`。
- **自訂 Base Image**：若專案需要特殊環境（如 CUDA、nerfstudio、PyTorch 等），你需要決定是否使用非預設的 base image。見下方「自訂 Base Image 規則」。

**語言和框架暫不決定**——除非使用者在描述中明確指定（如「用 Python 做...」），否則留待進入開發容器後由 Project Claude Code 與使用者討論決定。

將你的判斷結果展示給使用者確認，使用者可以調整。

### 3. 建立目錄結構
```bash
mkdir -p repo/.devcontainer repo/src
```
（data/ 和 secrets/ 已由 init.sh 建立）

### 4. 寫入 project-config.json

在 /workspace 根目錄建立 project-config.json，記錄專案配置（供 host 腳本讀取）：

```json
{
  "project_name": "<專案名稱>",
  "project_type": "<你判斷的類型>",
  "description": "<使用者的專案描述>",
  "language": "undecided",
  "framework": "undecided",
  "ports": [3000],
  "services": [],
  "mcp_search": true,
  "gstack": false,
  "gpu": false,
  "container_user": "node"
}
```

- `language` / `framework`：若使用者未指定，填 `"undecided"`
- `ports`：你根據專案類型自動分配的 port，無需暴露則為 `[]`
- `services`：你推斷需要的外部服務，無則為 `[]`
- `mcp_search`：是否啟用網路搜尋能力（透過 MCP Search Server），`true` 或 `false`
- `gstack`：是否安裝 gstack 及其依賴（Bun、Playwright），`true` 或 `false`
- `gpu`：是否啟用 GPU 直通（`--gpus all`），需要 CUDA/GPU 計算的專案設為 `true`
- `container_user`：容器內的非 root 使用者名稱。預設 `"node"`（node:20 base image）。若使用自訂 base image，**必須**設為該 image 中實際存在的使用者，或你在 Dockerfile 中建立的使用者名稱
- host 的 start.sh 和 enter.sh 會在 runtime 讀取此檔案來設定 port 映射、MCP 連線、gstack 持久化、GPU 和使用者

### 5. 客製化並寫入 Devcontainer 檔案

讀取 templates/devcontainer/ 中的模板作為參考，客製化後寫入 repo/.devcontainer/：

#### 自訂 Base Image 規則

預設 base image 是 `node:20`（內建 `node` 使用者，home 目錄 `/home/node`）。

若專案需要特殊環境（例如 CUDA、nerfstudio、PyTorch 官方 image 等），你**可以**更換 base image，但**必須遵守以下規則**：

1. **查詢 base image 的使用者**：使用 web search 或查閱官方文件，確認 base image 的預設使用者。若 image 預設為 root 或沒有非 root 使用者，你必須在 Dockerfile 中用 `useradd` 建立一個。
2. **project-config.json 中設定 `container_user`**：必須與 Dockerfile 中的 `USER` 指令和實際使用者名稱一致。host 的 start.sh 和 enter.sh 會讀取此欄位。
3. **Dockerfile 中所有路徑必須對應使用者**：
   - `chown` 指令中的使用者名稱
   - `/home/<user>/` 路徑（.claude、.bun、.gstack 等）
   - `USER` 指令
   - sudoers 設定中的使用者名稱
4. **必須保留的元素**（無論使用什麼 base image）：
   - 基礎工具：iptables, ipset, iproute2, dnsutils, jq, tmux, sudo
   - Claude Code 安裝（npm install -g @anthropic-ai/claude-code）
   - 防火牆腳本複製和 sudo 權限
   - Node.js（如果 base image 沒有，需要安裝）
   - 非 root 使用者執行（安全性要求）
   - tmux 滑鼠設定：`echo 'set -g mouse on' > /home/<container_user>/.tmux.conf`（並 chown 給該使用者）

**Dockerfile**：
- **預設情況**（node:20 base）：從 templates/devcontainer/Dockerfile 複製，保持原樣
- **自訂 base image**：以模板為參考，重新編寫 Dockerfile，確保上述必要元素都包含。特別注意使用者名稱的一致性。
- `# {{ADDITIONAL_PACKAGES}}` 位置留空——語言/框架安裝由 Project Claude Code 負責
- **必須保留**所有基礎工具安裝、Claude Code 安裝、防火牆腳本複製
- 若使用者已明確指定語言，才在此處加入對應 RUN 指令
- **gstack 處理**（注意：路徑中的使用者名稱必須與 `container_user` 一致）：
  - 若 `gstack: true`：將 `# {{GSTACK_DEPS}}` 替換為：
    ```dockerfile
    # 安裝 Bun（gstack 依賴，放在 cache bust 前保持快取）
    RUN curl -fsSL https://bun.sh/install | bash
    ENV PATH=$PATH:/home/<container_user>/.bun/bin
    # 安裝 Playwright 系統依賴（放在 cache bust 前保持快取）
    USER root
    RUN npx playwright install-deps chromium
    USER <container_user>
    ```
    將 `# {{GSTACK_INSTALL}}` 替換為：
    ```dockerfile
    # 安裝 gstack
    RUN git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git /home/<container_user>/.claude/skills/gstack && \
        cd /home/<container_user>/.claude/skills/gstack && \
        ./setup
    ```
  - 若 `gstack: false`：將 `# {{GSTACK_DEPS}}` 和 `# {{GSTACK_INSTALL}}` 整行移除或留為註解

**devcontainer.json**：
- 從 templates/devcontainer/devcontainer.json 複製
- 替換 `{{PROJECT_NAME}}` 為實際專案名稱
- `remoteUser` 必須與 `container_user` 一致

**init-firewall.sh**：
- 從 templates/devcontainer/init-firewall.sh 直接複製到 repo/.devcontainer/

### 6. 寫入 Project Claude Code 配置

讀取 templates/claude/CLAUDE.md，替換 `{{PROJECT_DESCRIPTION}}` 為使用者的專案描述和你的判斷結果（類型、服務、port 等）。
寫入 repo/CLAUDE.md。

### 7. 寫入 .gitignore

複製 templates/gitignore 到 repo/.gitignore。

### 8. 建立 bootstrap-manifest.md

在 /workspace 根目錄建立 bootstrap-manifest.md，記錄：
- 建立日期
- 使用者原始描述
- 你的判斷結果（類型、port、服務）和判斷原因
- 語言/框架狀態（undecided 或使用者指定的）
- 此檔案讓未來的 Bootstrap session 和 Project Claude Code 能理解脈絡

### 9. 輸出摘要

告訴使用者：
- ✓ 專案結構已建立
- ✓ project-config.json 已建立（port 設定由 start.sh 自動讀取）
- 語言/框架狀態：若為 undecided，說明進入開發容器後由 Project Claude Code 決定
- 退出此 Bootstrap 容器後，執行以下步驟：
  1. `cd $HOST_PROJECT_DIR`
  2. `./scripts/build.sh` （建構開發容器映像）
  3. `./scripts/start.sh` （啟動容器，自動建立 Docker network、啟用防火牆）
  4. `./scripts/enter.sh` （進入容器）
  5. `claude --dangerously-skip-permissions` （啟動 Project Claude Code 開始開發）
- 提醒使用者：Project Claude Code 會負責 git 初始化和版本控制
- 提醒使用者：若要用自己的 git 身份，進入容器後執行：
  ```
  git config user.name "你的名字"
  git config user.email "你的 email"
  ```

### 注意
- 你在容器中運行，**沒有 docker 命令**
- 不要嘗試執行 docker 命令
- **不要寫入 scripts/ 目錄**——腳本由 host 產生且為唯讀
- **不要執行 git 命令**——版本控制由 Project Claude Code 負責
- PROJECT_NAME 和 HOST_PROJECT_DIR 環境變數由 init.sh/bootstrap.sh 傳入
