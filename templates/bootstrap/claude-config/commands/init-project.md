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
  "mcp_search": true
}
```

- `language` / `framework`：若使用者未指定，填 `"undecided"`
- `ports`：你根據專案類型自動分配的 port，無需暴露則為 `[]`
- `services`：你推斷需要的外部服務，無則為 `[]`
- `mcp_search`：是否啟用網路搜尋能力（透過 MCP Search Server），`true` 或 `false`
- host 的 start.sh 會在 runtime 讀取此檔案來設定 port 映射和 MCP 連線

### 5. 客製化並寫入 Devcontainer 檔案

讀取 templates/devcontainer/ 中的模板作為參考，客製化後寫入 repo/.devcontainer/：

**Dockerfile**：
- 從 templates/devcontainer/Dockerfile 複製，保持原樣
- `# {{ADDITIONAL_PACKAGES}}` 位置留空——語言/框架安裝由 Project Claude Code 負責
- **必須保留**所有基礎工具安裝、Claude Code 安裝、防火牆腳本複製
- 若使用者已明確指定語言，才在此處加入對應 RUN 指令

**devcontainer.json**：
- 從 templates/devcontainer/devcontainer.json 複製
- 替換 `{{PROJECT_NAME}}` 為實際專案名稱

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
