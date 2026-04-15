---
name: create-skill
description: 將重複性的工作流程封裝為新的 skill。當使用者說「把這個流程存起來」「建立一個指令」時使用。
disable-model-invocation: true
---

為當前專案建立新的可重複使用 skill：

1. 確認 $ARGUMENTS 描述的流程值得封裝（至少涉及 2 個以上步驟）
2. 決定命名（kebab-case，簡短明確）
3. 在 `.claude/skills/<name>/` 下建立目錄
4. 寫入 `SKILL.md`，包含：
   ```yaml
   ---
   name: <名稱>
   description: <清楚描述用途和觸發時機，讓未來 session 能自動辨識>
   ---
   ```
   後接步驟化指令
5. 若 skill 有副作用（部署、發送訊息等），加上 `disable-model-invocation: true`
6. 告知使用者新 skill 已建立，可用 `/<name>` 調用或由 CC 自動使用

注意：
- 不要創建過於細粒度的 skill（單一命令不需要封裝）
- description 要具體，包含觸發關鍵字，讓 CC 知道何時使用
- 如果流程涉及特定路徑或檔案，在指令中明確寫出
