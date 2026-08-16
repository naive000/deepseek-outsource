---
name: deepseek-outsource
description: Directly operates DeepSeek harness (dsh, web UI at http://127.0.0.1:3080/) via the browserclaw MCP browser to outsource a coding subtask, run it in an isolated git worktree, monitor progress, and independently verify + merge the result. Use this skill whenever the user wants to hand off/outsource a coding task, a code review, a simplification pass, or a translation/content job to DeepSeek — phrases like "丟給 DeepSeek 跑", "分包給 DeepSeek", "叫 DeepSeek 去改", "outsource this to deepseek", "delegate this to deepseek", "dsh 那邊處理一下" all trigger this, even if the user doesn't mention worktree, browserclaw, or dsh by name. Do NOT use this for tasks Claude Code should just do itself, or for operating dsh's web UI for exploration/reference purposes (that's a separate manual/reference skill).
---

# DeepSeek Outsource — 把 coding 分包給 DeepSeek 跑

Claude Code(CC,你自己)全程直接操作 browserclaw 去指揮 DeepSeek。使用者不用碰瀏覽器。

**這份 skill 的存在前提**:整套流程建立在「CC 直接操作 browserclaw 控制 dsh 網頁」上,下面第 4-8 步全部是實測記錄下來的操作路徑跟陷阱,目的是讓每一次委派都不用重新摸索,直接加速。跟 `deepseek-manual`(dsh UI 操作手冊)共用同一個前提,兩份文件互相參照。

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
打開 dsh 頁面,**直接點側邊欄的「新建会话」按鈕**開新會話(這是純前端 SPA,導航回根網址不會清空畫面,只會恢復上一個瀏覽過的 session——不要用「回根網址」當開新會話的手段,沒有用)。

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
**固定每 10 分鐘檢查一次**(不可調整)。看「對話」分頁(排版過的閱讀視圖)快速掃進度;要精確判斷做了什麼動作時看「軌跡」分頁(原始事件表格,含完整參數),比對話分頁可靠。不要更密集地檢查,也不要自己排更短的輪詢間隔。

### 第 9 步 — 完工判定
依任務類型看對應的產出物(見上面任務類型表)。

### 第 10 步 — CC 獨立驗收
- **逐 commit 讀 diff**——不是只看 DeepSeek 的完工報告或自查結果。DeepSeek 的自查是「交件前品管」,CC 這步是「收件品管」,兩者不能互相取代。
- 獨立重跑全部品質關卡:typecheck / lint / build / 專案特定檢查。**自己重新跑一次,不要相信 DeepSeek 回報的跑測試結果**——如果需要另開虛擬環境驗證(例如 Python venv),CC 自己的沙箱通常不給直接寫 `/tmp`,要用 `$TMPDIR`。
- 如果 DeepSeek 沒有主動 commit 改動(任務書沒明講的話很可能不會),CC 這步順手幫它 commit 一次再繼續驗收/merge。
- Code Review 類型:抽查幾條具體發現,對照真實資料/行為驗證是否屬實。

### 第 11 步 — Merge 閘門
CC **不可自動 merge**。跟使用者確認一次(文字回覆「可以合併」之類,或用 `AskUserQuestion`)才能繼續。這關不能被自動化跳過——merge 決策屬於「複雜決策」,拍板的人是使用者。

### 第 12 步 — Merge
使用者確認後,CC 執行 merge 回 main。DeepSeek 全程不碰這步。

### 第 13 步 — 收尾
刪除 worktree、刪除分支,需要的話重新部署。

## Browserclaw 操作已知陷阱

實測撞過的坑,遇到不要慌,照這裡處理:

- **「新建会话」不是靠回根網址**:回根網址只會恢復上一個瀏覽過的 session,不會清空(純前端 SPA)。要開新會話,直接點側邊欄的「新建会话」按鈕。
- **清空訊息框失敗**:用 `fill` 帶空字串會出 `InputValidationError`。改用 `click` 聚焦欄位,接著 `press: Control+a`、再 `press: Delete`。
- **element ref 失效**:頁面導航/送出/重新渲染後,舊的 `[ref=eN]` 會失效,操作前先重新 `snapshot`。
- **斷線重連後分頁擁有權消失**:重新用 `tabs` 開新分頁,不要沿用舊的 tab id。**開新分頁後,「回根網址恢復上次 session」這件事不保證成立**(MVP 2.0 實測撞過:重連後的新分頁直接進到空白的「选择工作区」畫面,沒有恢復到原本正在監控的 session)。這時候不要照上一條的邏輯瞎等,直接展開側邊欄,在 session 樹裡找回原本的 workspace/session 節點點進去。
- **權限檔位選擇**:三檔(Read Only / Workspace Write / Full access),預設 Workspace Write,Full access 要使用者額外同意才能開。
- **`/goal` 送出後輸入框不會清空**:這是正常現象,不是操作失敗,不用重複清空或重送。
- **完工判定訊號**:goal 完成時,對話裡會出現一則「上下文注入 tool-goal complete: ...」的系統事件,DeepSeek 的收尾回報通常會用「改了什麼 / 驗收條件 / 自查清單」這種結構化小標題——看到這個格式基本可以認定完工,不用每次都去翻軌跡分頁逐條確認。
- **DeepSeek 側環境坑:worktree 沒有 pytest,且 `pip install --user` 常被 PEP 668(externally-managed-environment)擋下**——這是預期內會發生的事,不算 DeepSeek 出錯。DeepSeek 通常會自己改用 worktree 外的 venv 或 `uv` 裝,這是正確處理方式,但要注意它會不會把安裝路徑弄進白名單範圍內。
- **測試工具本身會在 worktree 留下白名單外的副產物**:`pytest` 執行會產生 `.pytest_cache/`,匯入模組會產生 `__pycache__/`——這些不是 DeepSeek「自己寫的」,但一樣算「動到白名單以外的檔案」,驗收時要連這些一起檢查有沒有清乾淨,不是只看有沒有多出非預期的 `.py` 檔。
- **`.claude/.cc-writes/` 空目錄是平台沙箱的基礎設施產物**,跟 DeepSeek 的交付內容無關,已經被全域 gitignore(`~/.config/git/ignore` 的 `**/.claude/.cc-writes/`)排除、git 完全看不到它。看到這個目錄不用緊張,不算 DeepSeek 動了不該動的東西。

## 跟另一個 skill 的分工

這個 skill 管「委派工作流程」(討論→worktree→dispatch→監控→驗收→merge)。dsh 網頁 UI 本身各項功能的操作手冊(設定、預設模式、命令選單細節等)是另一個獨立 skill `deepseek-manual` 的範圍,不在這裡重複。
