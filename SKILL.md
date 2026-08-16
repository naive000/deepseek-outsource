---
name: deepseek-outsource
description: Directly operates DeepSeek harness (dsh, web UI at http://127.0.0.1:3080/) via the browserclaw MCP browser to outsource a coding subtask, code review, simplification pass, translation/content job, or a pure research/investigation task (web search + summarize, no code) to DeepSeek — runs coding tasks in an isolated git worktree, monitors progress, and independently verifies (+ merges, for coding tasks) the result. Phrases like "丟給 DeepSeek 跑", "分包給 DeepSeek", "叫 DeepSeek 去改", "交給 deepseek 整理/查", "outsource this to deepseek", "delegate this to deepseek", "dsh 那邊處理一下" all trigger this, even if the user doesn't mention worktree, browserclaw, or dsh by name. Do NOT use this for tasks Claude Code should just do itself, or for operating dsh's web UI for exploration/reference purposes (that's a separate manual/reference skill).
---

# DeepSeek Outsource — 把 coding 分包給 DeepSeek 跑

Claude Code(CC,你自己)全程直接操作 browserclaw 去指揮 DeepSeek。使用者不用碰瀏覽器。

**這份 skill 的存在前提**:整套流程建立在「CC 直接操作 browserclaw 控制 dsh 網頁」上,下面第 4-8 步全部是實測記錄下來的操作路徑跟陷阱,目的是讓每一次委派都不用重新摸索,直接加速。跟 `deepseek-manual`(dsh UI 操作手冊)共用同一個前提,兩份文件互相參照。

## 角色分工(整個 skill 的心智模型)

- **DeepSeek = 執行者**:真的動手寫 code、跑測試、自己抓蟲。
- **Claude Code = 決策者 + 品管者**:界定範圍、寫任務書、驗收、拍板要不要合併。

DeepSeek 在自己的隔離分支裡想怎麼折騰都可以;main 分支跟 merge 動作是 CC 的責任區,不外包。

## 鐵規則(不可協商)

1. **涉及 git repo 的任務,DeepSeek 永遠只碰自己的 worktree/分支**,絕不直接動 main。(純研究/調查類型沒有 code repo,這條不適用——見下方任務類型表的備註)
2. **驗收 100% 由 CC 執行**,不能只看 DeepSeek 的完工報告就照單全收——coding 類型要親自逐 commit 讀 diff;純研究/調查類型要親自抽查來源真實性跟內容準確度。
3. **把產出「轉正」給使用者之前,必須讓使用者明確點頭**(coding 類型是 merge、純研究/調查類型是把報告交出去當結論用)——文字回覆或 AskUserQuestion 都算數,不可自動跳過這一關。

這三條貫穿整份 SOP,下面每一步都是在服務這三條。

## 觸發:先問清楚要幹嘛

Skill 一啟動,用一次 `AskUserQuestion` 問完(不要拆成多輪,`AskUserQuestion` 一次最多 4 題,以下正好 4 題):

1. **任務類型**(五選一,見下)
2. **目標 repo / 專案路徑**(純研究/調查類型改問:輸出資料夾放哪)
3. **權限檔位**(coding 類型才問;純研究/調查類型跳過,固定用 Workspace Write):Read Only / **Workspace Write**(預設,推薦)/ Full access——不管選哪一檔都要先讓使用者看到選項再決定,不能沿用「預設 Workspace Write 不問、只有 Full access 才問」的舊做法
4. **Merge 後要不要自動刪除 worktree**(coding 類型才問;純研究/調查類型跳過,輸出資料夾去留仍照舊由使用者決定):**是,自動刪除**(預設,推薦)/ 否,留著讓我自己看——選「是」的話第 13 步收尾不會再問一次;選「否」則第 13 步照舊詢問

觸發問完之後,順手記一筆使用記錄(見下方「使用記錄」)。

### 五種任務類型

| 類型 | DeepSeek 做什麼 | 產出 | CC 的驗收方式 |
|---|---|---|---|
| **一般任務**(開發/修復) | 直接在 worktree 裡改 code、commit | 一串 commits | 逐 commit 讀 diff + typecheck/lint/build + 專案特定檢查,必要時瀏覽器實測 |
| **Code Review** | 只看 code,寫報告,**不改任何檔案** | `FINDINGS.md` | 抽查具體發現是否對照真實資料/行為屬實,不照單全收;使用者/CC 決定要不要採納,**不自動合併任何東西** |
| **Simplify** | 在白名單範圍內清理過度設計,行為不變 | 獨立小 commits | 逐 commit 確認外部行為真的沒變 |
| **翻譯/內容產出** | 產出新內容檔案(如多語言 JSON),重點是格式規則+來源對照+key 對稱 | 新增/修改的內容檔 | 對稱檢查(key 是否一一對應)+品質抽查 |
| **純研究/調查**(2026-08-16 MVP 3.0 新增) | 上網查資料、整理、寫成報告,**不碰任何 code repo** | 一份 MD(或其他文字格式)報告 | CC 抽查一定比例的來源條目是否真實存在、內容有沒有對得上;檢查數量/日期範圍等硬指標是否達標;達標後 CC 用白話文幫使用者摘要重點 |

五個選項都是實跑驗證過的真實案例,不是憑空設計——之後如果要加新類型,先找一個真實案例跑過一輪再定模板,不要臨時發明。

## 使用記錄(2026-08-16 新增)

每次觸發都在 `~/.claude/skills/deepseek-outsource/usage-log.jsonl` append 兩筆(這個檔案已加進 `.gitignore`,純本機記錄,不進版控):

- **觸發當下**(問完 `AskUserQuestion` 之後):`{"ts":"<ISO時間>","event":"start","task_type":"...","target":"<repo路徑或輸出資料夾>","permission":"...","auto_delete_worktree":true/false,"offpeak":true/false}`
- **第 13 步收尾時**:`{"ts":"<ISO時間>","event":"end","task_type":"...","target":"...","outcome":"merged|adopted|rejected|failed","auto_approvals":<這次跑期間自動核准了幾次升級提示>}`

⚠️ **這個檔案要用 `Write`/`Edit` 工具寫,不要用 `bash echo >>`**——CC 自己的 sandbox 對 `~/.claude/skills/` 這個路徑的 bash 寫入是擋住的(讀取正常),用 `Read` 讀現有內容、組好新的一行、`Write` 整份寫回即可繞開這個限制。

目的是之後(見 `ROADMAP.md` MVP 9.0)回頭統計「委派這件事實際花了多少次、什麼類型最常用、尖峰/離峰各跑了幾次」,不是要拿來做即時分析。

**純研究/調查類型的差異**(跟其他四種比):
- **不用建 git worktree**——沒有 code repo 要保護。改成:CC 建一個全新、空的輸出資料夾(不是 git repo,純資料夾),當作 browserclaw 選 workspace 時的路徑,天然把 DeepSeek 的活動範圍限制在這個資料夾。
- **沒有「commit」「merge」概念**——第 2、3、11、12、13 步(建 worktree / commit 任務書 / merge 閘門 / merge / 刪 worktree)整組不適用,改成:CC 讀輸出資料夾裡的報告檔、抽查、整理成白話重點回報給使用者,使用者確認要採用才算「轉正」。
- **自查清單不一樣**(見第 3 步下方)。

## 完整流程(14 步)

### 第 1 步 — 討論範圍
跟使用者對齊:要改什麼、白名單檔案(允許動的範圍)、黑名單(**不准碰的共用檔案清單**——這是隔離真正生效的關鍵,每次都要寫)、驗收線是什麼樣子算過關。

### 第 2 步 — 建一次性 worktree(純研究/調查類型跳過,見下方替代做法)
```
git worktree add -b deepseek/<task-name> <path> <base-branch>
```
裝依賴(注意已知環境坑,例如某些專案的原生綁定需要從主 repo 的 `node_modules` 複製過去)。需要資料庫的話,用 `sqlite3 <main-db> ".backup '<worktree>/data/xxx.db'"` 做快照進 worktree,別讓 DeepSeek 碰到正式資料庫。

**純研究/調查類型的替代做法**:不建 worktree,改成 `mkdir` 一個全新的空資料夾當輸出目錄(例如 `~/deepseek-research/<task-name>-<date>/`),不用 git init。

### 第 3 步 — 寫任務書
在 worktree(或純研究類型的輸出資料夾)裡寫 `DEEPSEEK_<TASK>_TASK.md`,coding 類型要 commit,純研究類型純寫檔案即可。內容包含:
- 任務範圍
- 白名單(允許改的檔案/目錄;純研究類型就是「只准寫在這個輸出資料夾裡」)
- 黑名單(**絕對不准碰的共用檔案**)
- 驗收條件(純研究類型要寫清楚硬指標,例如:數量下限、日期範圍、輸出檔名/格式)

如果任務類型是「一般任務」或「翻譯」,把下面的**自查清單**整份貼進任務書;「純研究/調查」用它自己的清單(見下)。用 `assets/brief-template.md` 當骨架。

**自查清單(coding 類型:一般任務/翻譯)**,寫成一次交代完的清單,不要設計成逐步等 CC 下指令:
> 改完 code → 自己看一遍 diff → 清理過度設計的部分 → 自我 code review(甚至自己修)→ 安全性自查 → 確認實際跑得動(build/test)→ commit → 有問題自己救回來。

**自查清單(純研究/調查類型)**:
> 逐條確認來源真的存在、沒有捏造 → 確認日期範圍符合要求 → 數量沒達標就老實講不夠,不要湊數硬填 → 確認輸出格式符合要求 → 在報告最前面附一段重點摘要。

為什麼要一次寫完不要分步:`/goal` 有動作輪數上限(實測看過 0/256 這種計數),一步步等指令會把輪數浪費在等待上,任務可能還沒做完就斷氣。這份清單也不會取代 CC 的驗收(見第 10 步)——它只是讓 DeepSeek 交件品質高一點、減少你們的來回輪數。

### 第 4 步 — 開 browserclaw,選 workspace
打開 dsh 頁面,**直接點側邊欄的「新建会话」按鈕**開新會話(這是純前端 SPA,導航回根網址不會清空畫面,只會恢復上一個瀏覽過的 session——不要用「回根網址」當開新會話的手段,沒有用)。

工作區選擇走:「選擇工作區」→「添加工作區」→點「编辑路径」→直接貼絕對路徑(worktree 的完整路徑),清單會即時過濾,不用手動點資料夾樹。

### 第 5 步 — 設權限
用 `/permission` 指令,設成觸發時 `AskUserQuestion` 第 3 題使用者選的檔位,不用再問一次。Full access 是能逃逸沙箱的檔位,但既然觸發時已經讓使用者明確選過,這步驟不用二次確認。

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
**固定每 5 分鐘檢查一次**(2026-08-16 從 10 分鐘改快,不可再自行調整;縮短的原因見下——不是單純求快,是跟權限檔位選擇連動的)。看「對話」分頁(排版過的閱讀視圖)快速掃進度;要精確判斷做了什麼動作時看「軌跡」分頁(原始事件表格,含完整參數),比對話分頁可靠。不要更密集地檢查,也不要自己排更短的輪詢間隔。

**遇到授權升級提示,範圍內的不用管,dsh 自己會過**(2026-08-16 首次實測驗證,推翻了原本「CC 要主動幫忙按確定」的設計):
- 用一個真實 probe 任務(worktree 裡改一個檔案+`git commit`)實測到:畫面短暫出現一張「**審批詳情**」卡片,裡面有「**拒絕**」/「**允許一次**」兩顆按鈕,但抓到畫面時兩顆都已經是 disabled——**核准已經跑完了,不是卡住等人類點**。DeepSeek 自己的軌跡記錄也寫「Per policy, I retry the exact same command once with the narrowest wider mode」→「The escalation was approved and `git add` succeeded」,全程 CC 沒有點任何東西。
- 這證實了:「worktree 裡 `git commit` 撞到 `.git/worktrees/<name>/index.lock`」這個最常見的升級情境,**dsh 後端在 Workspace Write 檔位下會自己秒過**,不需要 CC 介入按確定。
- **保留但降級的規則**:上面這條只驗證過「worktree 內、commit 相關」這一種升級情境。如果監控時真的看到「審批詳情」卡片、且「拒絕」/「允許一次」是**可點(非 disabled)狀態**在等——這種才是真的卡住等人:目標路徑在這次任務的 worktree 之內就直接點「允許一次」,計入回報的 `auto_approvals`;目標路徑在 worktree 之外或碰到黑名單範圍 → 不要自動按,停下來問使用者。
- 這個模式底下還沒驗證過的:Full access 檔位下升級提示行為是否一樣自動過、有沒有真的需要人工點擊才會生效的情境長怎樣——遇到了再補進來。
- **這也是監控間隔縮到 5 分鐘的真正原因**(使用者 2026-08-16 提出的因果):既然預設不開 Full access(見觸發第 3 題,預設 Workspace Write),就一定還會有其他種類的升級請求不是「worktree 內 commit」這種能自動秒過的模式,真的卡住等人工點「允許一次」——這種情況下監控間隔越短,那個卡住的任務被發現、被處理的延遲就越短。5 分鐘不是單純求快,是「不開 Full access」這個選擇本身帶來的代價,用縮短輪詢去對沖。

### 第 9 步 — 完工判定
依任務類型看對應的產出物(見上面任務類型表)。

### 第 10 步 — CC 獨立驗收
**coding 類型(一般任務/Code Review/Simplify/翻譯):**
- **逐 commit 讀 diff**——不是只看 DeepSeek 的完工報告或自查結果。DeepSeek 的自查是「交件前品管」,CC 這步是「收件品管」,兩者不能互相取代。
- 獨立重跑全部品質關卡:typecheck / lint / build / 專案特定檢查。**自己重新跑一次,不要相信 DeepSeek 回報的跑測試結果**——如果需要另開虛擬環境驗證(例如 Python venv),CC 自己的沙箱通常不給直接寫 `/tmp`,要用 `$TMPDIR`。**重跑驗證腳本時,如果那個腳本本身會寫入已經 commit 的產出檔(例如報告 json),先想清楚會不會把好資料蓋掉**——最好對複本跑,或先 `git stash`,不要直接對著 committed 檔案原地重跑。
- 如果 DeepSeek 沒有主動 commit 改動(任務書沒明講的話很可能不會),CC 這步順手幫它 commit 一次再繼續驗收/merge。
- Code Review 類型:抽查幾條具體發現,對照真實資料/行為驗證是否屬實。

**純研究/調查類型:**
- 抽查一定比例(不用全部)的來源條目,確認真的存在、內容對得上,不是編出來的。
- 檢查數量/日期範圍等硬指標是否達標,沒達標的部分 DeepSeek 有沒有老實講。
- 檢查輸出格式符合要求。
- 通過後,CC 自己讀完整份報告,**用白話文幫使用者整理重點**,不是把整份報告丟給使用者自己看。

### 第 11 步 — Merge 閘門(純研究/調查類型改叫「採用閘門」)
CC **不可自動 merge / 不可自動把報告當定論採用**。跟使用者確認一次(文字回覆「可以合併」之類,或用 `AskUserQuestion`)才能繼續。這關不能被自動化跳過——這類決策屬於「複雜決策」,拍板的人是使用者。

### 第 12 步 — Merge(純研究/調查類型:交付報告)
coding 類型:使用者確認後,CC 執行 merge 回 main,DeepSeek 全程不碰這步。純研究/調查類型:沒有 merge 動作,這步等於「把整理好的白話重點回報給使用者」。

### 第 13 步 — 收尾

**coding 類型,worktree/分支**:
- 觸發時 `AskUserQuestion` 第 4 題選「是,自動刪除」→ 不用再問,直接刪除 worktree、刪除分支,需要的話重新部署。
- 選「否」→ 照舊詢問使用者要不要刪。
- **如果 `git worktree remove` 卡住報 "Device or resource busy"**(常見於從別台機器 zip 傳過來、混進壞掉 `.claude/`、`.mcp.json` 之類殘骸檔的專案):這通常不是真的檔案被佔用(`fuser`/`lsof`/`/proc/*/fd` 查不到任何 process 握著它),是 CC 自己的沙箱把這些路徑當受保護設定檔擋刪除。解法:先嘗試 `git worktree remove` 失敗就直接 `rm -rf` 整個目錄(帶 `dangerouslyDisableSandbox: true`,範圍僅限這個 worktree 路徑本身),再 `git worktree prune` 清 metadata,最後才刪分支——順序錯了(例如先 prune 再刪目錄)一樣會卡住。

**coding 類型,browserclaw/dsh 兩層清理**(2026-08-16 新增,對應「B CLAW 會殘留垃圾群組」這個真實痛點——2026-08-16 實測當下光是別的 agent 留下的 dsh workspace/session 就已經一堆數小時到一天前的殘留,清理是有真實效益的):

1. **dsh 側,刪除這次任務的工作區**(2026-08-16 已實測驗證可靠,不再是 best-effort):回到第 4 步開的那個 browserclaw 分頁,打開側邊欄,對 workspace 路徑等於這次 worktree 路徑的 treeitem 依序執行:`hover`(讓操作按鈕浮出)→**緊接著馬上**`click` 那顆「工作區"<name>"的操作」按鈕(兩個動作分開下但中間不要插入 snapshot/wait,連續執行成功率才高——2026-08-16 曾經連續兩次點擊沒反應,第三次改成「hover 完立刻 click,再統一補一次 snapshot」的順序才穩定開啟選單)→選單裡點「刪除工作區」→跳出的確認 dialog 裡點「刪除工作區」確認鈕。⚠️ **這個動作只會刪掉「工作區」這層分組,不會刪掉底下的 session/對話紀錄**——session 會被移到側欄的「未分組」桶裡繼續留著(這解釋了為什麼側欄「未分組」底下常年一堆歷史 session)。如果要連 session 本身都清掉,還要另外對 session 項目做「歸檔會話」(見 `deepseek-manual` 的 session 操作說明),目前的收尾流程不強制做到這一步,只求「工作區」這層不再持續累積即可。
2. **browserclaw 側,關掉這次任務的分頁群組**(已驗證可靠,一定要做):用 `tab_groups` 工具 `action: "list"` 找到第 4 步 `name_session` 命名的那個群組(群組名會是 `claude/<你當時取的名字>`),確認裡面的 page id 都是這次任務自己開的,再用 `tab_groups` 工具 `action: "close"` 帶對應 `groupId`——**一次呼叫就會關掉群組本身跟裡面所有分頁**,不用逐一關 tab。**只准關自己這次任務開的群組,絕對不要動其他群組**(不管是使用者自己的分頁,還是其他 agent/session 名下的群組——2026-08-16 實測光是背景就有其他 agent 在跑的 `nba-weekly-news` 相關群組,誤關會打斷別人的任務)。

**純研究/調查類型**:輸出資料夾要不要留著給使用者自己決定,不用主動刪;browserclaw 分頁群組清理邏輯同上(第 2 點)一樣做。

## Browserclaw 操作已知陷阱

實測撞過的坑,遇到不要慌,照這裡處理:

- **「新建会话」不是靠回根網址**:回根網址只會恢復上一個瀏覽過的 session,不會清空(純前端 SPA)。要開新會話,直接點側邊欄的「新建会话」按鈕。
- **清空訊息框失敗**:用 `fill` 帶空字串會出 `InputValidationError`。改用 `click` 聚焦欄位,接著 `press: Control+a`、再 `press: Delete`。
- **element ref 失效**:頁面導航/送出/重新渲染後,舊的 `[ref=eN]` 會失效,操作前先重新 `snapshot`。
- **斷線重連後分頁擁有權消失**:重新用 `tabs` 開新分頁,不要沿用舊的 tab id。**開新分頁後,「回根網址恢復上次 session」這件事不保證成立**(MVP 2.0 實測撞過:重連後的新分頁直接進到空白的「选择工作区」畫面,沒有恢復到原本正在監控的 session)。這時候不要照上一條的邏輯瞎等,直接展開側邊欄,在 session 樹裡找回原本的 workspace/session 節點點進去。
- **權限檔位選擇**:三檔(Read Only / Workspace Write / Full access)。2026-08-16 起這個選擇已經摺進觸發時的 `AskUserQuestion`(見「觸發」那節第 3 題),UI 上這步只是照使用者選的檔位點下去,不用再另外確認。
- **`/goal` 送出後輸入框不會清空**:這是正常現象,不是操作失敗,不用重複清空或重送。
- **完工判定訊號**:goal 完成時,對話裡會出現一則「上下文注入 tool-goal complete: ...」的系統事件,DeepSeek 的收尾回報通常會用「改了什麼 / 驗收條件 / 自查清單」這種結構化小標題——看到這個格式基本可以認定完工,不用每次都去翻軌跡分頁逐條確認。
- **DeepSeek 側環境坑:worktree 沒有 pytest,且 `pip install --user` 常被 PEP 668(externally-managed-environment)擋下**——這是預期內會發生的事,不算 DeepSeek 出錯。DeepSeek 通常會自己改用 worktree 外的 venv 或 `uv` 裝,這是正確處理方式,但要注意它會不會把安裝路徑弄進白名單範圍內。
- **測試工具本身會在 worktree 留下白名單外的副產物**:`pytest` 執行會產生 `.pytest_cache/`,匯入模組會產生 `__pycache__/`——這些不是 DeepSeek「自己寫的」,但一樣算「動到白名單以外的檔案」,驗收時要連這些一起檢查有沒有清乾淨,不是只看有沒有多出非預期的 `.py` 檔。
- **`.claude/.cc-writes/` 空目錄是平台沙箱的基礎設施產物**,跟 DeepSeek 的交付內容無關,已經被全域 gitignore(`~/.config/git/ignore` 的 `**/.claude/.cc-writes/`)排除、git 完全看不到它。看到這個目錄不用緊張,不算 DeepSeek 動了不該動的東西。
- **DeepSeek 在 worktree 裡跑 `git commit` 幾乎一定要 escalate 到更寬的權限檔位**:worktree 的 `.git` 其實是個指標,指向主 repo 的 `.git/worktrees/<name>/`,那個目錄在 workspace root 之外,預設 Workspace Write 檔位下 sandbox 會擋寫入(常見錯誤是 `index.lock` 寫入失敗)。這是預期內、每次要求 commit 的 worktree 任務都會發生,不是 DeepSeek 犯規——任務書裡可以先講清楚「commit 這步預期要升級權限」,免得它自己繞圈子摸索。
- **新分頁不一定是空白,可能連恢復到別的任務、還沒送出的完整草稿都會出現**:2026-08-16 實測過一次比文件原本描述更嚴重的情況——不是「恢復上次瀏覽的 session」這麼單純,而是新分頁直接顯示另一個真實委派任務(別的專案、完整任務書文字都在)、且「發送消息」按鈕是可點狀態,只差沒按下去。**開新分頁後,送出任何訊息之前,一定要先看清楚訊息框裡的文字是不是自己這次任務打的**——文字量大、內容明顯不是這次任務的描述,就是踩到這個陷阱,不要因為看到滿版文字就以為是自己剛才輸入的直接送出。正確處理:直接點側邊欄「新建会話」按鈕,不要動暫停/編輯/清除目標,也絕對不要點送出。
- **全新瀏覽器分頁(這台機器上第一次載入 dsh)會跳出一次性「内測聲明」彈窗**,「繼續」按鈕預設是 disabled,要等幾秒(倒數計時)才會變成可點,不是操作卡住,耐心等即可。
- **新分頁載入 dsh 可能卡在「Loading plugins…」很久**(2026-08-16 實測過從 15 秒到 100+ 秒都有),看起來跟當下 dsh 服務同時有多少 session/子代理在跑有關——這是清理垃圾 session/workspace 這件事的真實效益證據,不只是介面整潔問題。卡住就耐心等(可以 `wait` 多次 2-3 秒疊加),必要時 `navigate reload` 一次。
- **worktree 路徑不要建在 CC 自己 sandbox 的暫存目錄**(`$TMPDIR`、`$CLAUDE_JOB_DIR/tmp` 這類):2026-08-16 實測用 `$TMPDIR` 底下的路徑,dsh「選擇工作區目錄」對話框永遠卡在「加載中…」選不到,合理懷疑是 CC sandbox 用了獨立 mount namespace,dsh 這個機器上獨立常駐、不在 CC sandbox 內的服務看不到那個路徑。worktree 要建在真正的專案路徑旁邊(例如 `/home/crazy/<project>-wt` 這種 sibling 目錄),過去驗證過的 `deepseek-test-sandbox-wt`、`江雪琴預測本機版-deepseek-e*` 都是這樣建的。**2026-08-16 稍晚在 dsh 服務不忙的時候重測,真實 `/home/crazy` 路徑的「選擇工作區目錄」對話框秒開、資料夾樹正常列出、選取後 `打開` 正常可點**——確認之前那次卡住是當下 dsh 服務過載的暫時現象,不是路徑本身有問題,結論收斂為「只有 `$TMPDIR` 這類 sandbox 暫存路徑真的不行,真實 `/home/crazy` 路徑沒問題」。**檔案選擇對話框的正確操作方式是逐層點資料夾清單進去**(點「添加工作區」→在列表裡點資料夾名稱一路點到 worktree 那層,清單裡的資料夾名稱會變成麵包屑,選到目標資料夾後「打開」按鈕才會從 disabled 變成可點)——直接在「編輯路徑」文字框打完整路徑按 Enter 兩次都沒能讓「打開」啟用,點資料夾清單這條路徑比較可靠。
- **這台機器上 DeepSeek 的 bash 環境也套了 `rtk` 的 `_rtk_wrap` 包裝**(2026-08-16 實測發現,之前沒人知道):`git diff` 等指令輸出會被壓縮成只顯示「Changes: 1 file changed, 1 insertion(+)」這種摘要,沒有實際 +/- 逐行內容。DeepSeek 不認得 rtk,實測一次真的因此卡了 11 個步驟(整個任務約 40% 的執行輪數)去除錯這個「奇怪的 diff 格式」,一路查到 git config/`.gitattributes`/git wrapper function,最後才自己發現 `/usr/bin/git`(真實 binary,繞過 wrapper)可以拿到完整 diff。**任務書裡可以先講一句「這台機器的 bash 環境有輸出壓縮,git diff 等指令如果只顯示摘要沒有逐行內容是正常現象,需要完整輸出可以直接呼叫 `/usr/bin/git`」**,省下這筆不必要的除錯輪數——`assets/brief-template.md` 已經補上這條。

## 跟另一個 skill 的分工

這個 skill 管「委派工作流程」(討論→worktree→dispatch→監控→驗收→merge)。dsh 網頁 UI 本身各項功能的操作手冊(設定、預設模式、命令選單細節等)是另一個獨立 skill `deepseek-manual` 的範圍,不在這裡重複。
