---
name: init-project
description: 初始化新專案的開發環境：產生 repo/.devcontainer/Dockerfile、project-config.json、開發代理指引與自我管理檔案。只在使用者輸入 /init-project 時執行。
disable-model-invocation: true
---

初始化當前專案目錄。

使用者已經透過 init.sh 建立了此專案目錄。你在 Docker 容器中運行，工作目錄是 /workspace（專案根目錄）。
現在你需要根據使用者的需求，客製化並建立完整的專案結構。

**權限與限制（由 image 內的 managed settings 強制，無法更改）**：
- 你只能編輯 `repo/`、`project-config.json`、`bootstrap-manifest.md`；`scripts/`、`templates/`、`.claude/` 為唯讀。
- 寫入 `repo/.devcontainer/` 與 `repo/.claude/` 時，Claude Code 會請使用者確認——這是刻意設計的把關點，寫入前先簡短說明內容。
- 不需要 `mkdir`：用 Write 工具寫檔會自動建立目錄。
- 沒有 docker、git、curl 可用；需要查資料時用 WebSearch / WebFetch。

## 步驟

### 1. 確認環境
- 用 `printenv PROJECT_NAME` 取得專案名稱，用 `printenv HOST_PROJECT_DIR` 取得 host 上的專案絕對路徑。
- 模板在 `templates/` 下（唯讀）。

### 2. 詢問使用者

只問一個問題：**「你想做什麼？請描述你的專案想法。」**

使用者會用自然語言描述他們的專案想法（例如：「我想做一個能自動抓取新聞的工具」）。
不要逐項詢問類型、語言、port 等技術細節。

你根據描述**自行判斷**：
- **專案類型**：web / api / cli / automation / ai-ml / mobile / experimental
- **需要的外部服務**：根據描述推斷（例如「存用戶資料」→ 可能需要 PostgreSQL）
- **Port**：需要對外提供服務時，依專案類型列出常見 port（如 web app → 3000，API → 8080）；不需要暴露 port 則留空。
- **搜尋能力**：若專案可能需要查詢網路資料（技術文件、API 文檔、錯誤排查等），設 `mcp_search` 為 `true`。大多數開發專案建議啟用。
- **額外放行網域**：開發容器的防火牆預設只放行 Claude / OpenAI、npm、PyPI、Go、crates.io、GitHub、VS Code 相關網域。若專案明顯需要其他來源（例如 AI/ML 專案下載模型常需要 `huggingface.co`），列入 `extra_allowed_domains`；不確定就留空，開發時被擋再加。
- **Agent（容器內的開發代理）**：容器內可用 **Claude Code**（預設）或 **OpenAI Codex CLI**。**主動詢問使用者要用哪一個**。
  - 若選 **codex**：
    1. **認證**：在容器內執行 `codex login --device-auth`（需先在 ChatGPT 的安全設定啟用裝置碼登入），或把已登入電腦上的 `~/.codex/auth.json` 複製到 host 的 `codex-data/`；登入狀態持久化於 codex-data（掛載為 `~/.codex`）。
    2. **筆記 MCP**：預設開啟（`notes_mcp`，見步驟 3）。host 端依 `mcp-access` 食譜備妥內網 + 共用 token 後，新專案零手動步驟即自動接上；某專案不接才設 `"notes_mcp": false`。
  - `agent` 影響 Dockerfile 的安裝內容、專案指引檔（claude→`CLAUDE.md`；codex→`AGENTS.md`）、以及 start.sh/enter.sh 的行為（皆已 agent-aware）。
- **GPU**：若描述提到 GPU、CUDA、模型訓練、推理、3D 重建、機器學習等，設 `gpu` 為 `true`。
- **自訂 Base Image**：若專案需要特殊環境（如 CUDA、PyTorch 官方 image 等），見下方「自訂 Base Image 規則」。

**語言和框架暫不決定**——除非使用者在描述中明確指定（如「用 Python 做...」），否則留待進入開發容器後由開發代理與使用者討論決定。

將你的判斷結果展示給使用者確認，使用者可以調整。

### 3. 寫入 project-config.json

在 `/workspace/project-config.json` 記錄專案配置（供 host 腳本讀取；開發容器內可在 `/project-config.json` 唯讀查看）：

```json
{
  "project_name": "<專案名稱>",
  "project_type": "<你判斷的類型>",
  "description": "<使用者的專案描述>",
  "language": "undecided",
  "framework": "undecided",
  "ports": [3000],
  "services": [],
  "agent": "claude",
  "mcp_search": true,
  "extra_allowed_domains": [],
  "gpu": false,
  "container_user": "node"
}
```

- `language` / `framework`：若使用者未指定，填 `"undecided"`
- `ports`：需要幾個 port 就列幾個（1024–65535），無需暴露則為 `[]`。start.sh 會從 10000–19999 分配實際 port（host 與容器相同），並以 `$PORT`（第一個）與 `$PORT_0`、`$PORT_1`… 傳入容器
- `services`：你推斷需要的外部服務，無則為 `[]`
- `agent`：容器內開發代理，`"claude"`（預設）或 `"codex"`。start.sh／enter.sh 會依此分流認證、持久化與 MCP 設定。
- **筆記 MCP（`notes_mcp`，預設開啟 — 不必寫此欄位）**：若 host 上已依 `/srv/data/projects/ai-note/repo/docs/mcp-access-recipe.md` 建好 `mcp-access` 內網與共用 token，start.sh 會自動把容器接上並寫入 MCP 設定，**新專案零手動步驟**。
  - 要讓某專案**不接**才加 `"notes_mcp": false`。
  - token 來源：全機共用 `~/ai-note-secrets/dev-token`；需 private/admin 的專案放專屬 token 到 `secrets/notes-token`（覆蓋共用那枚）。
  - claude → 合併寫入 `/workspace/.mcp.json`（server 名 `ai-note-live`，headers Bearer）；codex → 追加寫入 `~/.codex/config.toml`（`[mcp_servers.ai-note-live]` url + `bearer_token_env_var=NOTES_TOKEN`，token 不落地）。
  - 防火牆模板已含靜態放行 `172.30.0.0/24`（未 attach 時無害）；start.sh 會 POST `tools/list` 驗證並印 200/401/403/000 診斷。
- `mcp_search`：是否啟用網路搜尋能力（透過 MCP Search Server），`true` 或 `false`（codex 與 claude 皆支援，start.sh 會用對應格式寫入）
- `extra_allowed_domains`：開發容器額外放行的網域（字串陣列；只接受一般網域名稱，不支援萬用字元，最多 50 個）
- `gpu`：是否啟用 GPU 直通（`--gpus all`），需要 CUDA/GPU 計算的專案設為 `true`（host 需安裝 nvidia-container-toolkit）
- `container_user`：容器內的非 root 使用者名稱。預設 `"node"`。若使用自訂 base image，**必須**設為該 image 中實際存在的使用者，或你在 Dockerfile 中建立的使用者名稱（只能用小寫英文、數字、`_`、`-`，不可為 root，否則 start.sh 會拒絕啟動）

### 4. 寫入開發容器 Dockerfile

讀取 `templates/devcontainer/Dockerfile` 作為基礎，寫入 `repo/.devcontainer/Dockerfile`。

防火牆由 host 端建置的防火牆 image 從外部套用，開發容器內**不需要**防火牆腳本；也**不要**產生 devcontainer.json（用 VS Code 時改用 Attach to Running Container，見步驟 8）。

**預設情況**（`node:22-bookworm` base）：
- 從模板複製。
- `agent: "claude"`：`# === AGENT_INSTALL BEGIN ===` 與 `# === AGENT_INSTALL END ===` 之間的 Claude Code 安裝**保持原樣**。
- `agent: "codex"`：把 BEGIN 與 END 標記之間的內容替換為：
  ```dockerfile
  # 安裝 OpenAI Codex CLI
  RUN npm install -g @openai/codex \
      && echo "Installed Codex: $(codex --version 2>&1 | head -1)"
  ```
- `# {{ADDITIONAL_PACKAGES}}` 位置留空——語言/框架安裝由開發代理負責；若使用者已明確指定語言，才在此處加入對應 RUN 指令。

#### 自訂 Base Image 規則

若專案需要特殊環境（例如 CUDA、PyTorch 官方 image 等），你**可以**更換 base image，但**必須遵守以下規則**：

1. **查詢 base image 的使用者**：用 WebSearch / WebFetch 查閱官方文件，確認 base image 的預設使用者。若 image 預設為 root 或沒有非 root 使用者，你必須在 Dockerfile 中用 `useradd` 建立一個。
2. **project-config.json 中設定 `container_user`**：必須與 Dockerfile 中的 `USER` 指令和實際使用者名稱一致。
3. **Dockerfile 中所有路徑必須對應使用者**：`chown` 指令、`/home/<user>/` 路徑（.claude、.codex）、`USER` 指令。
4. **必須包含的元素**：
   - Node.js 22 以上（Claude Code 的 npm 套件要求；base image 沒有就要安裝）
   - curl、iproute2（start.sh 需要）、git、jq、tmux
   - Agent 安裝區塊（依 `agent` 安裝 Claude Code 或 Codex）
   - 建立 `/workspace`、`/home/<container_user>/.claude`、`/home/<container_user>/.codex` 並 chown 給該使用者
   - 非 root 使用者執行（安全性要求）
   - tmux 滑鼠設定：`echo 'set -g mouse on' > /home/<container_user>/.tmux.conf`（並 chown 給該使用者）

### 5. 寫入開發代理指引

**依 `agent` 欄位選擇要寫哪個指引檔**（Claude Code 讀 `CLAUDE.md`；Codex 讀 `AGENTS.md`）：

- 若 `agent: "claude"`：讀取 `templates/claude/CLAUDE.md`，替換 `{{PROJECT_DESCRIPTION}}` 為專案描述與你的判斷（類型、服務、port 等），寫入 `repo/CLAUDE.md`。
- 若 `agent: "codex"`：改寫入 `repo/AGENTS.md`。以 `templates/claude/CLAUDE.md` 為骨架但**針對 Codex 調整**：
  - 標題與角色改為 Codex；說明 Codex 自動讀 `AGENTS.md`。
  - 開發指令從 `claude --dangerously-skip-permissions` 改為 `codex`；首次登入用 `codex login --device-auth`（需先在 ChatGPT 安全設定啟用裝置碼登入）。
  - 若有接 MCP（search、ai-note），加一節說明工具由 start.sh 寫入 `~/.codex/config.toml`、如何排查。
  - 「自我管理」改為：每次 session 開始先讀 `docs/project-goals.md` 與 `docs/decisions.md` 並持續維護；可重複的多步驟流程封裝成 `.agents/skills/<name>/SKILL.md`（Codex 會自動載入）。
  - 刪除只適用 Claude Code 的內容（`.claude/rules`、auto-memory、`/skill-name` 呼叫方式等）。

### 6. 建立自我管理檔案

跨 session 的持久化機制（追蹤目標、記錄決策、可重用流程）。**依 agent 分流**：

- 若 `agent: "claude"`（Claude Code 會自動載入 `.claude/rules/` 與 skills）：
  - **Rules**：讀 `templates/claude/rules/project-goals.md`，將 `{{PROJECT_GOALS}}` 替換為核心目標，寫入 `repo/.claude/rules/project-goals.md`；複製 `templates/claude/rules/decisions.md` 到 `repo/.claude/rules/decisions.md`。
  - **Skills**：複製 `templates/claude/skills/review-progress/SKILL.md` 與 `templates/claude/skills/create-skill/SKILL.md` 到 `repo/.claude/skills/<name>/SKILL.md`。
- 若 `agent: "codex"`（Codex 從 `.agents/skills` 載入 skills，不讀 `.claude/`）：
  - 建立 `repo/docs/project-goals.md`（以 `templates/claude/rules/project-goals.md` 為基礎、去掉 frontmatter、填入核心目標）與 `repo/docs/decisions.md`（以 `templates/claude/rules/decisions.md` 為基礎、去掉 frontmatter，可預先記入本次 agent/MCP 的決策）。
  - 複製 `templates/codex/skills/review-progress/SKILL.md` 與 `templates/codex/skills/create-skill/SKILL.md` 到 `repo/.agents/skills/<name>/SKILL.md`。
  - **不要**建立 `repo/.claude/`（對 Codex 是無用的空結構）。

### 7. 寫入 .gitignore

複製 `templates/gitignore` 到 `repo/.gitignore`。

### 8. 建立 bootstrap-manifest.md 並輸出摘要

在 `/workspace/bootstrap-manifest.md` 記錄：
- 建立日期（`date`）
- 使用者原始描述
- 你的判斷結果（類型、agent、port、服務、extra_allowed_domains、GPU、base image）和判斷原因
- 語言/框架狀態（undecided 或使用者指定的）

此檔案讓未來的 Bootstrap session 和開發代理能理解脈絡。

然後告訴使用者：
- ✓ 專案結構已建立、project-config.json 已建立
- 語言/框架狀態：若為 undecided，說明進入開發容器後由開發代理決定
- 退出此 Bootstrap 容器後，執行以下步驟：
  1. `cd $HOST_PROJECT_DIR`
  2. `./scripts/build.sh`（建構開發容器映像）
  3. `./scripts/start.sh`（啟動容器，自動建立 Docker network、套用防火牆）
  4. `./scripts/enter.sh`（進入容器）
  5. 啟動開發代理：
     - `agent: "claude"` → `claude --dangerously-skip-permissions`
     - `agent: "codex"` → `codex`（首次先 `codex login --device-auth`）
- 開發時若網域被防火牆擋住：在 host 的 `project-config.json` 的 `extra_allowed_domains` 加入網域，再執行 `./scripts/firewall.sh`（不需重建、不需重啟容器）
- 想用 VS Code：先執行 `start.sh`，再用 Dev Containers 擴充套件的「Attach to Running Container」連到 `devcontainer-<專案名稱>`，開啟 `/workspace`
- 若 MCP Search Server 不在預設的 9100 port：執行 start.sh 前在 host 設定環境變數 `MCP_SEARCH_PORT`；server 需監聽對外介面（非僅 127.0.0.1）
- 開發代理會負責 git 初始化和版本控制；若要用自己的 git 身份，進入容器後執行：
  ```
  git config user.name "你的名字"
  git config user.email "你的 email"
  ```

### 注意
- 你在容器中運行，**沒有 docker、git、curl 命令**，不要嘗試執行
- **不要寫入 scripts/、templates/、.claude/**——它們是唯讀的
- PROJECT_NAME 和 HOST_PROJECT_DIR 環境變數由 init.sh/bootstrap.sh 傳入
