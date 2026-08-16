---
name: deepseek-outsource
description: Directly operates DeepSeek harness (dsh, web UI at http://127.0.0.1:3080/) via the browserclaw MCP browser to outsource a coding subtask, run it in an isolated git worktree, monitor progress, and independently verify + merge the result. Use this skill whenever the user wants to hand off/outsource a coding task, a code review, a simplification pass, or a translation/content job to DeepSeek — phrases like "丟給 DeepSeek 跑", "分包給 DeepSeek", "叫 DeepSeek 去改", "outsource this to deepseek", "delegate this to deepseek", "dsh 那邊處理一下" all trigger this, even if the user doesn't mention worktree, browserclaw, or dsh by name. Do NOT use this for tasks Claude Code should just do itself, or for operating dsh's web UI for exploration/reference purposes (that's a separate manual/reference skill).
---

# DeepSeek Outsource — 把 coding 分包給 DeepSeek 跑

Claude Code(CC,你自己)全程直接操作 browserclaw 去指揮 DeepSeek。使用者不用碰瀏覽器。

## 角色分工(整個 skill 的心智模型)

- **DeepSeek = 執行者**:真的動手寫 code、跑測試、自己抓蟲。
- **Claude Code = 決策者 + 品管者**:界定範圍、寫任務書、驗收、拍板要不要合併。

DeepSeek 在自己的隔離分支裡想怎麼折騰都可以;main 分支跟 merge 動作是 CC 的責任區,不外包。

## 鐵規則(不可協商)

1. **DeepSeek 永遠只碰自己的 git worktree/分支**,絕不直接動 main。
2. **Diff 審查與 merge 100% 由 CC 執行**,DeepSeek 不自己 merge、CC 也不能只看 DeepSeek 的完工報告就簽名放行——一定要親自逐 commit 讀 diff。
3. **Merge 前必須讓使用者明確點頭**(文字回覆或 AskUserQuestion 都算數),不可自動跳過這一關。

這三條貫穿整份 SOP,下面每一步都是在服務這三條。

## 觸發:先問清楚要幹嘛

Skill 一啟動,用一次 `AskUserQuestion` 問完(不要拆成多輪):

1. **任務類型**(四選一,見下)
2. **目標 repo / 專案路徑**

### 四種任務類型

| 類型 | DeepSeek 做什麼 | 產出 | CC 的驗收方式 |
|---|---|---|---|
| **一般任務**(開發/修復) | 直接在 worktree 裡改 code、commit | 一串 commits | 逐 commit 讀 diff + typecheck/lint/build + 專案特定檢查,必要時瀏覽器實測 |
| **Code Review** | 只看 code,寫報告,**不改任何檔案** | `FINDINGS.md` | 抽查具體發現是否對照真實資料/行為屬實,不照單全收;使用者/CC 決定要不要採納,**不自動合併任何東西** |
| **Simplify** | 在白名單範圍內清理過度設計,行為不變 | 獨立小 commits | 逐 commit 確認外部行為真的沒變 |
| **翻譯/內容產出** | 產出新內容檔案(如多語言 JSON),重點是格式規則+來源對照+key 對稱 | 新增/修改的內容檔 | 對稱檢查(key 是否一一對應)+品質抽查 |

四個選項都是今晚實跑驗證過的真實案例,不是憑空設計——之後如果要加新類型,先找一個真實案例跑過一輪再定模板,不要臨時發明。

## 完整流程(14 步)

### 第 1 步 — 討論範圍
跟使用者對齊:要改什麼、白名單檔案(允許動的範圍)、黑名單(**不准碰的共用檔案清單**——這是隔離真正生效的關鍵,每次都要寫)、驗收線是什麼樣子算過關。

### 第 2 步 — 建一次性 worktree
```
git worktree add -b deepseek/<task-name> <path> <base-branch>
```
裝依賴(注意已知環境坑,例如某些專案的原生綁定需要從主 repo 的 `node_modules` 複製過去)。需要資料庫的話,用 `sqlite3 <main-db> ".backup '<worktree>/data/xxx.db'"` 做快照進 worktree,別讓 DeepSeek 碰到正式資料庫。

### 第 3 步 — 寫任務書
在 worktree 裡寫 `DEEPSEEK_<TASK>_TASK.md` 並 commit,內容包含:
- 任務範圍
- 白名單(允許改的檔案/目錄)
- 黑名單(**絕對不准碰的共用檔案**)
- 驗收條件

如果任務類型是「一般任務」或「翻譯」,把下面的**自查清單**整份貼進任務書。用 `assets/brief-template.md` 當骨架。

**自查清單**(只用在一般任務/翻譯,寫成一次交代完的清單,不要設計成逐步等 CC 下指令):
> 改完 code → 自己看一遍 diff → 清理過度設計的部分 → 自我 code review(甚至自己修)→ 安全性自查 → 確認實際跑得動(build/test)→ 有問題自己救回來。

為什麼要一次寫完不要分步:`/goal` 有動作輪數上限(實測看過 0/256 這種計數),一步步等指令會把輪數浪費在等待上,任務可能還沒做完就斷氣。這份清單也不會取代 CC 的驗收(見第 10 步)——它只是讓 DeepSeek 交件品質高一點、減少你們的來回輪數。

### 第 4 步 — 開 browserclaw,選 workspace
打開 dsh 頁面。**先回根網址再開新 session**——「新建会话」按鈕有時會誤跳進既有進行中的 session,不會給你真正的空白會話。

工作區選擇走:「選擇工作區」→「添加工作區」→點「编辑路径」→直接貼絕對路徑(worktree 的完整路徑),清單會即時過濾,不用手動點資料夾樹。

### 第 5 步 — 設權限
用 `/permission` 指令。**預設用 Workspace Write**。不要自己選 Full access——那是能逃逸沙箱的檔位,只有使用者明確同意才能開。

### 第 6 步 — 尖峰時段檢查
這是送出 `/goal` 前的最後關卡,因為第 1-5 步都不花 DeepSeek API 的錢,只有這步之後才開始燒錢。

DeepSeek API 是峰谷定價:
- **尖峰**(北京/台灣時間,同一個 UTC+8,不用換算):09:00–12:00、14:00–18:00
- **離峰**:其餘時段,價格是尖峰的一半

抓當下時間:
- **命中尖峰** → 用 `AskUserQuestion` 跳出選項問使用者:「現在直接跑(付尖峰價)」還是「排到離峰再跑」
- **沒命中(在離峰)** → 不用問,直接往下走第 7 步

### 第 7 步 — 下指令
點「命令」按鈕選單裡的 `/goal`,它會把 `/goal ` 文字填進訊息框(不會自動送出)。把任務書內容貼進去,送出。

### 第 8 步 — 監控
**固定每 10 分鐘檢查一次**(不可調整),看「對話」或「軌跡」分頁確認進度。不要更密集地檢查,也不要自己排更短的輪詢間隔。

### 第 9 步 — 完工判定
依任務類型看對應的產出物(見上面任務類型表)。

### 第 10 步 — CC 獨立驗收
- **逐 commit 讀 diff**——不是只看 DeepSeek 的完工報告或自查結果。DeepSeek 的自查是「交件前品管」,CC 這步是「收件品管」,兩者不能互相取代。
- 獨立重跑全部品質關卡:typecheck / lint / build / 專案特定檢查。
- Code Review 類型:抽查幾條具體發現,對照真實資料/行為驗證是否屬實。

### 第 11 步 — Merge 閘門
CC **不可自動 merge**。跟使用者確認一次(文字回覆「可以合併」之類,或用 `AskUserQuestion`)才能繼續。這關不能被自動化跳過——merge 決策屬於「複雜決策」,拍板的人是使用者。

### 第 12 步 — Merge
使用者確認後,CC 執行 merge 回 main。DeepSeek 全程不碰這步。

### 第 13 步 — 收尾
刪除 worktree、刪除分支,需要的話重新部署。

## Browserclaw 操作已知陷阱

實測撞過的坑,遇到不要慌,照這裡處理:

- **「新建会话」跳進舊 session**:開新會話前先回 dsh 根網址。
- **清空訊息框失敗**:用 `fill` 帶空字串會出 `InputValidationError`。改用 `click` 聚焦欄位,接著 `press: Control+a`、再 `press: Delete`。
- **element ref 失效**:頁面導航/送出/重新渲染後,舊的 `[ref=eN]` 會失效,操作前先重新 `snapshot`。
- **斷線重連後分頁擁有權消失**:重新用 `tabs` 開新分頁,不要沿用舊的 tab id。
- **權限檔位選擇**:三檔(Read Only / Workspace Write / Full access),預設 Workspace Write,Full access 要使用者額外同意才能開。

## 跟另一個 skill 的分工

這個 skill 管「委派工作流程」(討論→worktree→dispatch→監控→驗收→merge)。dsh 網頁 UI 本身各項功能的操作手冊(設定、預設模式、命令選單細節等)是另一個獨立 skill 的範圍,不在這裡重複。
