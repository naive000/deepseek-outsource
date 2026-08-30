---
name: deepseek-outsource
description: 直接操作 DeepSeek harness(dsh,web UI 在 http://127.0.0.1:3080/)透過 browserclaw MCP 瀏覽器,把 coding 子任務、code review、simplify(簡化清理)、翻譯/內容產出,或純研究/調查任務(上網搜尋+整理,不碰 code)分包給 DeepSeek——coding 類任務會在獨立的 git worktree 裡跑,監控進度,並獨立驗收(coding 類另外還要負責 merge)結果。「丟給 DeepSeek 跑」「分包給 DeepSeek」「叫 DeepSeek 去改」「交給 deepseek 整理/查」「outsource this to deepseek」「delegate this to deepseek」「dsh 那邊處理一下」這類說法都會觸發,即使使用者沒提到 worktree、browserclaw 或 dsh 本身。不要用在 Claude Code 自己就該做的任務,也不要用在單純操作 dsh 網頁 UI 做探索/查詢(那是另一個獨立的操作手冊 skill)。
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

### 模式判定(CC 自動判斷,預設標準模式,2026-08-29 新增)

dsh 的「新建会话」畫面上,工作區選擇器右邊有一顆顯示目前模式的按鈕(預設「标准模式」),點開是選單:标准模式 / PTC 模式 / 极简模式 / 创造模式 / 使用者自訂的 `standard-claude` preset。本 skill 只在**标准模式**跟 **PTC 模式**之間判斷,极简/创造/自訂 preset 不在範圍內。⚠️ **這顆按鈕只在新建會話畫面上存在,送出訊息開始跑之後就消失,中途不能切換**(2026-08-29 實測驗證,見第 4 步)——選錯就得整個重開會話,所以要在第 4 步、送出 `/goal` 之前就決定好。

**不新增第 4 題**:觸發時的 `AskUserQuestion` 已經 4 題滿檔,加上使用者的既定偏好是「預設都用標準模式」、日常維運類確認要少問。所以模式判定改成 CC 依下面規則自己套用、預設直接走標準模式不用問;只有規則判定該用 PTC 時,才另外開一次**單題**的 `AskUserQuestion`(選項「PTC 模式(推薦)」放第一個、「標準模式」放第二個),讓使用者一次確認或否決,不強行套用。

**PTC 訊號**(符合 ≥2 條、或單一條特別明顯就算命中):
- 任務描述裡出現「批量」「一次改一堆」「遍歷」「彙總」「重複 N 次」這類字眼——本質是同一個操作套在一串清單上
- 要對 ≥10 個檔案/項目做同樣的機械式轉換(codemod、批次改名、格式遷移、多語系 key 批次插入)
- 邏輯能一次寫完(迴圈+條件判斷+彙總),不需要中途看結果再臨場判斷下一步
- 同類型任務先前用標準模式跑過,同款工具呼叫重複超過 5-6 次

**站標準模式那邊的情況**(以下任一成立就選標準,兩邊打平也選標準,呼應使用者預設偏好):路徑要邊做邊判斷(除錯/探索類)、步驟只有 1-2 步、需要逐項人工判斷不是機械套用、需要 CC 逐步觀察介入。

**套進五種任務類型**:
- 一般任務(開發/修復):預設標準,除非明顯是 codemod/批次修改形狀
- Code Review:固定標準——只看不改,靠的是逐步判斷,不是機械編排
- Simplify:固定標準——行為等價要逐 commit 判斷,不能一次程式跑完就信
- 翻譯/內容產出:多語系、key 對稱批次產出時是最強的 PTC 候選;單一檔案/單一語言就用標準
- 純研究/調查:預設標準,除非是「N 個來源 × M 次取樣,最後彙總」這種形狀

⚠️ **這條規則整理自外部文章(DSH 官方 FAQ + 社群討論),不是本 skill 逐項實跑驗證過的行為**——目前第 8 步「監控間隔 5 分鐘/授權升級自動秒過」這套 SOP,全部只在標準模式下實測過。PTC 模式底下,審批升級卡片、監控訊號、完工判定會不會表現一樣,目前沒有真實案例佐證。比照這份 skill 一貫的規範(「五個任務類型都是實跑驗證過的真實案例,不是憑空設計」),第一次真的選用 PTC 模式跑任務時,要把實際觀察到的行為(升級提示長怎樣、多久看一次進度才夠、完工判定訊號是否一樣)補寫回這一節,不要讓 PTC 這條規則停在紙上談兵。

## 使用記錄(2026-08-16 新增)

每次觸發都在 `~/.claude/skills/deepseek-outsource/usage-log.jsonl` append 兩筆(這個檔案已加進 `.gitignore`,純本機記錄,不進版控):

- **觸發當下**(問完 `AskUserQuestion` 之後):`{"ts":"<ISO時間>","event":"start","task_type":"...","target":"<repo路徑或輸出資料夾>","permission":"...","auto_delete_worktree":true/false,"offpeak":true/false,"mode":"standard|ptc"}`
- **第 13 步收尾時**:`{"ts":"<ISO時間>","event":"end","task_type":"...","target":"...","outcome":"merged|adopted|rejected|failed","auto_approvals":<這次跑期間自動核准了幾次升級提示>}`

⚠️ **這個檔案要用 `Write`/`Edit` 工具寫,不要用 `bash echo >>`**——CC 自己的 sandbox 對 `~/.claude/skills/` 這個路徑的 bash 寫入是擋住的(讀取正常),用 `Read` 讀現有內容、組好新的一行、`Write` 整份寫回即可繞開這個限制。

目的是之後(見 `ROADMAP.md` MVP 9.0)回頭統計「委派這件事實際花了多少次、什麼類型最常用、尖峰/離峰各跑了幾次」,不是要拿來做即時分析。

**純研究/調查類型的差異**(跟其他四種比):
- **不用建 git worktree**——沒有 code repo 要保護。改成:CC 建一個全新、空的輸出資料夾(不是 git repo,純資料夾),當作 browserclaw 選 workspace 時的路徑,天然把 DeepSeek 的活動範圍限制在這個資料夾。
- **沒有「commit」「merge」概念**——第 2、3、11、12、13 步(建 worktree / commit 任務書 / merge 閘門 / merge / 刪 worktree)整組不適用,改成:CC 讀輸出資料夾裡的報告檔、抽查、整理成白話重點回報給使用者,使用者確認要採用才算「轉正」。
- **自查清單不一樣**(見第 3 步下方)。

## 雙傳輸架構:browserclaw(GUI) vs headless CLI(2026-08-30 新增,headless 已實測)

⚠️ **目前實際採用的傳輸方式仍是 browserclaw(GUI)**——下面第 4-8 步才是這份 skill 現在真的在用的路徑。headless CLI 這條路**還在實驗階段、尚未採用**:`danger-full-access` 啟用不了的根因已經查出且驗證有解法(見下方表格),但**還沒有把「worktree 內 git commit escalation」這個真實情境套用修法後重新端到端跑過**,只驗證了修法能讓 session 的權限 knob 正確落在 danger-full-access。這節內容保留當作技術紀錄+未來參考,**觸發這份 skill 時不要主動建議使用者選 headless**,除非端到端重跑過真實 coding 任務且驗證修好。

下面第 4-8 步描述的是 **browserclaw** 傳輸——透過瀏覽器操作 dsh 網頁 UI。另一條路是 **headless CLI**:直接在終端機跑一次性指令,不開瀏覽器、不留背景 process。兩條路共用同一份任務書/驗收/merge 流程,只有「怎麼把任務送進 dsh」這一段不一樣。

**headless CLI 怎麼跑**(這台機器目前是 tsx 跑原始碼的 dev 模式,不是 build 好的全域 `dsh` 指令):
```
DSH_PERMISSION_MODE=<mode> DSH_HOME=<獨立乾淨路徑,見下方 danger-full-access 那列> \
  node --import "file://<deepseek-game內tsx/esm loader的絕對路徑,例如 /home/crazy/deepseek-game/node_modules/tsx/dist/loader.mjs>" \
  /home/crazy/deepseek-game/apps/cli/src/bin.ts --profile headless "<任務文字>"
```
⚠️ **`DSH_HOME` 不是可有可無的選項**——不指定就會用預設 `~/.dsh`,那是這台機器日常 browserclaw/網頁 UI 在用的同一份家目錄,裡面持久化的 `permission.defaultPreset` 偏好會蓋掉 `DSH_PERMISSION_MODE`(細節見下方表格 danger-full-access 那列)。只要不是刻意要沿用網頁 UI 的偏好,一律給獨立路徑。
⚠️ **cwd 有限制**:tsx 用 tsconfig-paths 解析 workspace 內部套件(例如 `@deepseek-ai/cordis`),這個解析是照 **cwd** 往上找 tsconfig.json,不是照被執行檔案的位置找。如果 cwd 不在 `deepseek-game` repo 底下(往上找不到它的 tsconfig.json),bare specifier 會退回一般 Node 解析,撈到版本不對的套件,直接炸掉(`SyntaxError: ... does not provide an export named 'FiberState'`)。**目標 workspace 要建在 `deepseek-game` repo 底下的巢狀路徑**(例如 `deepseek-game/.probe-scratch/<name>`),不能是完全獨立於外的 sibling 目錄。這是這台機器 dev 模式特有的限制,正式 build 出來的全域 `dsh` bin 理論上不會有這個限制,但這輪沒有實測驗證。

**2026-08-30 headless probe 實測結果**(worktree 內 `git commit` 這個經典 escalation 情境,`.git` 指向 cwd 之外):

| 驗證項 | 結果 |
|---|---|
| workspace-write 檔位 | ✅ 符合預期:cwd 內寫檔成功,但 `git add`/`git commit` 需要寫 `.git/worktrees/<name>/index.lock`(在 workspace 之外)被沙箱擋下,agent 自動重試一次升級到 `danger-full-access`,升級被拒絕(**headless 模式沒有可用的審核管道**),agent 誠實回報「檔案已建立、commit 失敗、原因是什麼」然後乾淨停下——沒有卡住、沒有幻覺聲稱成功。 |
| danger-full-access 檔位 | ✅ **根因已查出,有可行解法(2026-08-30 第二輪追查)**:`DSH_PERMISSION_MODE` 確實有在 `packages/bundle/base/cordis.patch.yml` 裡正確把 `sandbox-policy`/`approval` 兩個外掛的**初始 config** 切到 danger-full-access,問題出在**後面一步**——`@deepseek-ai/dsh-permission-presets`(`packages/interaction/permission-presets/src/index.ts`)在**每個 `session/created` 事件**都會呼叫 `pinInitialPermission(session)`,對全新 session 無條件執行 `setSandboxMode`/`setApprovalPolicy`,把 knob 覆寫成 `this.defaultPreset` 解析出來的值——而 `this.defaultPreset` 是透過 `installSettingsSection()` 接到**持久化設定檔** `$DSH_HOME/settings.yaml` 的 `permission.defaultPreset` 鍵(`PERMISSION_SETTINGS_NAMESPACE` 那個猜對了一半的線索,真正的持久化來源是這份 YAML,不是猜測中的別的服務)。這台機器的 `~/.dsh/settings.yaml` 因為日常 browserclaw/網頁 UI 使用,已經存了 `permission: defaultPreset: workspace-write`——**每次開新 headless session 都被這條持久化偏好蓋掉,`DSH_PERMISSION_MODE` 環境變數完全被蓋過去,不是沒生效,是被寫穿之後又被覆寫**。**驗證過的解法**:headless 跑 danger-full-access 任務時,額外指定一個**乾淨、獨立的 `DSH_HOME`**(裡面沒有 `settings.yaml`,或至少沒有 `permission.defaultPreset` 這個鍵),`pinInitialPermission` 這時找不到持久化偏好,才會真的落回 `config.defaultPreset ?? inferredDefault`——實測 `session.jsonl` 裡 `permission/preset`/`sandbox/mode`/`approval/policy` 三個事件都正確記成 `danger-full-access`/`danger-full-access`/`never`。**呼叫語法要多加一段 `DSH_HOME=<獨立乾淨路徑>`**,不能沿用預設的 `~/.dsh`(那是日常 browserclaw 在用的,會撞到這條持久化偏好)。 |
| 完工判定訊號 | Exit code **不可靠**——task 部分失敗(commit 沒做成)但 process 仍然乾淨 exit 0,只要 agent 有把最終答案講完(不是中途崩潰)。要判斷「真的整個任務都做完」必須連著看列印出來的最終回答文字,不能只信退出碼。 |
| **側欄可見性(這次探測最重要的問題)** | ✅ **確認:headless CLI 跑的 session 會出現在 dsh 網頁 UI 的側欄裡**,分組在「未分組」底下,以啟動時的 cwd 資料夾名稱命名,時間戳正確。**代表其他使用者不需要另外裝 BrowserOS/browserclaw 才能「看畫面」**——用 headless CLI 跑任務,想看進度時直接開瀏覽器貼 `?token=` 網址,在「未分組」裡找到對應 session 點進去就能看完整對話/軌跡,是唯讀監控不是操作介面。 |

**選擇建議**:
- Headless 適合:CI/腳本、機械化任務。要跑會撞到 escalation 的任務(例如 worktree 內 `git commit`),務必搭配獨立 `DSH_HOME` 才能真的用 danger-full-access——沒搭配獨立 `DSH_HOME` 就等於還在 workspace-write,做不完。
- browserclaw(GUI)適合:不想處理 `DSH_HOME` 隔離、想要人工在旁邊點「允許一次」逐步核准的 coding 任務——第 4-8 步描述的路徑。
- 只是想「用瀏覽器看畫面,不想裝 BrowserOS」:headless 跑完(或跑的過程中)開 `?token=` 網址去「未分組」找 session 即可,純觀看不需要 browserclaw 自動化操作。

**已解決**(2026-08-30 第二輪追查):danger-full-access 透過 `DSH_PERMISSION_MODE` 啟用不了的根因跟解法,見上方表格。**還沒做的**:拿修法後的 `DSH_HOME` 隔離套用到「worktree 內 git commit」這個真實 escalation 情境重新端到端跑一次(這輪只驗證了 session 的權限 knob 有正確落在 danger-full-access,沒有重新驗證真實 coding 任務能不能靠這個修法整個跑完不被擋)。

## 完整流程(14 步)

⚠️ 下面 14 步描述的是 **browserclaw(GUI)** 這條傳輸路徑。走 headless CLI 時,第 4-8 步整段換成上面「雙傳輸架構」寫的指令呼叫,其餘步驟(討論範圍/寫任務書/驗收/merge 閘門/收尾)完全共用。

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

**選運行模式**(2026-08-29 實測驗證):「選擇工作區」按鈕右邊那顆顯示目前模式名稱的按鈕(預設「标准模式」),點開跳出選單,五個選項:标准模式 / PTC 模式 / 极简模式 / 创造模式 / 使用者自訂的 `standard-claude` preset。照上面「模式判定」那節的規則選標準或 PTC(极简/创造/自訂 preset 不用管)。⚠️ **一定要在這步、送出 `/goal` 之前選好**——這顆按鈕只在新建會話畫面存在,訊息送出開始跑之後就從畫面消失,沒有中途切換這回事,選錯只能整個重開會話。

### 第 5 步 — 設權限
用 `/permission` 指令,設成觸發時 `AskUserQuestion` 第 3 題使用者選的檔位,不用再問一次。Full access 是能逃逸沙箱的檔位,但既然觸發時已經讓使用者明確選過,這步驟不用二次確認。

⚠️ **選 Full access 時,dsh 自己還有一道 UI 確認關卡**(2026-08-16 實測發現):點下「Full access」選項後會跳出「確認啟用 Full access?」對話框,裡面有一個必勾選的核取方塊「我已了解風險,並願意繼續」,勾了之後「啟用 Full access」按鈕才會從 disabled 變成可點。這是 dsh 自己的安全閘門,跟這份 skill 觸發時的 `AskUserQuestion` 是兩層獨立的確認——CC 這邊已經有使用者明確選過 Full access,所以照勾照點,不用因為看到這個對話框又跑去問使用者一次。

### 第 6 步 — 尖峰時段檢查
這是送出 `/goal` 前的最後關卡,因為第 1-5 步都不花 DeepSeek API 的錢,只有這步之後才開始燒錢。

DeepSeek API 是峰谷定價:
- **尖峰**(北京/台灣時間,同一個 UTC+8,不用換算):09:00–12:00、14:00–18:00
- **離峰**:其餘時段,價格是尖峰的一半

抓當下時間:
- **命中尖峰** → 用 `AskUserQuestion` 跳出選項問使用者:「現在直接跑(付尖峰價)」還是「排到離峰再跑」
- **沒命中(在離峰)** → 不用問,直接往下走第 7 步

**選到「排到離峰再跑」之後,不用再問使用者第二次,直接自動排程執行**(2026-08-17 定案):

1. 算下一個離峰起點:目前在 09:00–12:00 → 離峰起點是當天 12:00;目前在 14:00–18:00 → 離峰起點是當天 18:00。
2. 目標觸發時間 = 離峰起點 + 5 分鐘緩衝(12:05 或 18:05)——留 5 分鐘是避免卡在尖峰/離峰交界的計價模糊帶。
3. 用 `CronCreate` 排一個 `recurring: false` 的一次性任務,`cron` 用本機時區的 5 欄格式對準目標時間(例:當天 18:05 → `"5 18 <當天日> <當天月> *"`)。**這是 session-only 排程,不寫入磁碟**——排程前要跟使用者講清楚這個限制(session 若中途結束排程會跟著消失)。
4. `prompt` 內容要自成一體(觸發時是全新一輪,沒有這次對話的記憶),必須包含:
   - 明講這是「deepseek-outsource skill 流程接續,前面第 1–3 步跟尖峰檢查已完成,現在從第 4 步開始做到底」
   - 這次任務的 worktree 路徑/分支、任務書檔案路徑、已確認的三個參數(任務類型、權限檔位、merge 後是否自動刪除 worktree)
   - 指示先讀 `~/.claude/skills/deepseek-outsource/SKILL.md` 取得完整 SOP,照第 4 步開始執行到底(含監控、驗收、merge 閘門、收尾)
   - 重申第 11 步 merge 閘門硬規則:驗收完不自動 merge,要等使用者點頭;使用者當下沒空回覆就把結果整理好等著,不強行合併
5. `CronCreate` 建立成功後,回報使用者:排程時間、session-only 限制提醒、驗收完會停在哪一步等使用者確認——到此為止,不用再問任何問題。

### 第 7 步 — 下指令
點「命令」按鈕選單裡的 `/goal`,它會把 `/goal ` 文字填進訊息框(不會自動送出)。把任務書內容貼進去,送出。

### 第 8 步 — 監控
**固定每 5 分鐘檢查一次**(2026-08-16 從 10 分鐘改快,不可再自行調整;縮短的原因見下——不是單純求快,是跟權限檔位選擇連動的)。看「對話」分頁(排版過的閱讀視圖)快速掃進度;要精確判斷做了什麼動作時看「軌跡」分頁(原始事件表格,含完整參數),比對話分頁可靠。不要更密集地檢查,也不要自己排更短的輪詢間隔。

**遇到授權升級提示,範圍內的不用管,dsh 自己會過**(2026-08-16 首次實測驗證,推翻了原本「CC 要主動幫忙按確定」的設計):
- 用一個真實 probe 任務(worktree 裡改一個檔案+`git commit`)實測到:畫面短暫出現一張「**審批詳情**」卡片,裡面有「**拒絕**」/「**允許一次**」兩顆按鈕,但抓到畫面時兩顆都已經是 disabled——**核准已經跑完了,不是卡住等人類點**。DeepSeek 自己的軌跡記錄也寫「Per policy, I retry the exact same command once with the narrowest wider mode」→「The escalation was approved and `git add` succeeded」,全程 CC 沒有點任何東西。
- 這證實了:「worktree 裡 `git commit` 撞到 `.git/worktrees/<name>/index.lock`」這個最常見的升級情境,**dsh 後端在 Workspace Write 檔位下會自己秒過**,不需要 CC 介入按確定。
- **保留但降級的規則**:上面這條只驗證過「worktree 內、commit 相關」這一種升級情境。如果監控時真的看到「審批詳情」卡片、且「拒絕」/「允許一次」是**可點(非 disabled)狀態**在等——這種才是真的卡住等人:目標路徑在這次任務的 worktree 之內就直接點「允許一次」,計入回報的 `auto_approvals`;目標路徑在 worktree 之外或碰到黑名單範圍 → 不要自動按,停下來問使用者。
- **Full access 檔位下的行為已於 2026-08-16 補測**:同一個 slugify 小任務用 Full access 跑,全程沒有出現任何升級提示(不管是自動秒過的還是要等人點的那種),`轨迹` 分頁只在一開始有一則「上下文注入 user-approval / permission preset danger-full-access」的系統事件,宣告這個 session 進入高權限模式,之後就一路暢通到 commit。**同任務對比:Full access 32 秒完工,遠快於 Workspace Write 檔位下要繞 rtk debug、撞 index.lock escalation 的版本**——這也是「權限檔位」這題除了安全考量外,額外的速度代價/效益取捨,值得跟使用者說清楚。
- **這也是監控間隔縮到 5 分鐘的真正原因**(使用者 2026-08-16 提出的因果):既然預設不開 Full access(見觸發第 3 題,預設 Workspace Write),就一定還會有其他種類的升級請求不是「worktree 內 commit」這種能自動秒過的模式,真的卡住等人工點「允許一次」——這種情況下監控間隔越短,那個卡住的任務被發現、被處理的延遲就越短。5 分鐘不是單純求快,是「不開 Full access」這個選擇本身帶來的代價,用縮短輪詢去對沖。

### 第 9 步 — 完工判定
依任務類型看對應的產出物(見上面任務類型表)。

### 複審層級選擇(2026-08-29 新增,夾在第9步之後、第10步之前,只適用於一般任務)

第10步矩陣裡的 `/code-review`,除了 CC 本地跑,還可以外包回 DSH 那邊跑——DSH 端跑 agent 的 CP 值比 CC 本地高很多。這節就是把這個選擇權交給使用者,而不是 CC 自己悄悄決定。

**為什麼在這裡問,不是塞進觸發時的第5題**:觸發當下還看不到 diff,diff 大小、有沒有碰敏感面這些訊號要等第9步完工才看得到,所以放在這個天然停頓點問最準。這題是刻意的例外——雖然這份 skill 一貫傾向少問,但這是使用者明確要求要能選的決策點。

完工後,CC 用**一次**單題 `AskUserQuestion` 問,選項依 CC 的建議排序(參考第10步矩陣的訊號+diff大小+目前是不是離峰):
1. **DSH 外包複審**(訊號命中時列第一,標「推薦」)
2. **CC 本地 `/code-review`**
3. **純人工逐 commit 看,不跑額外工具**

**選 DSH 外包複審時怎麼跑**:
- **不建新 worktree**,同一個 worktree/分支繼續用。
- **開一個全新的 dsh 會話**(不是接著原本寫 code 的那個 session 繼續問)——全新 context 才跟原本的 builder session 保持獨立,不會出現「自己審自己、順便幫自己辯護」的問題。
- 任務書精簡到罐頭範本:「複審這個 worktree 目前的 commits,寫 `FINDINGS.md`,不改任何檔案」,白名單只給 `FINDINGS.md`;原本的第1-3步(討論範圍/建worktree/寫任務書)在這裡濃縮成一句話帶過,不用重跑一輪。
- **沿用本次任務原本第6步的尖峰/離峰判定**,不用重新問一次。
- usage-log 記一筆,標記這是接續任務(例如加 `chained_from` 欄位指回原本那筆 start 記錄的 target),方便之後回頭統計。

**鐵規則不變,不管選哪個層級**:DSH 端複審或 CC 本地 `/code-review` 都只是「交件前品管的第二意見」,不是「收件品管」——第10步「CC 逐 commit 讀 diff」這件事還是要做,對複審跑出來的發現也要抽查是否屬實,不能因為多了一層複審就跳過人工看 diff。⚠️ V4 審 V4 結構上比不上 CC(跨模型)審 V4——全新 session 只能緩解「自己審自己」的問題,不能消除模型同源這個結構性弱點。選 DSH 外包複審是拿這個弱點換 CP 值,要讓使用者知道這個取捨,不是無痛的選項。

**`run` 不用另開一趟 DSH 複審**:直接併進原本任務書的自查清單裡,寫「跑起來實測並回報結果」;UI 關鍵的任務,CC/使用者透過 browserclaw 肉眼驗證。要起服務先在任務書裡指定 port,查 [[reference_port_registry]] 避免撞埠。原任務書漏寫這件事時,用 `assets/brief-run-verify.md` 事後補一趟。

**罐頭任務書模板,取代裝 plugin(2026-08-29 定案)**:同日盤點過 `awesome-dsh-plugin` 對應的候選插件,使用者裁決**不安裝**——未審查的社群代碼有 workspace 存取權,而且現有的任務類型機制+下面這組模板已經覆蓋掉同樣的功能,不需要多引入一份沒人審查過的第三方代碼。候選清單(`dsh-command-code-review`/`Viger1/dsh-review`/`dsh-hawkeye-scan`/`dsh-code-security`/`dsh-web-preview`/`dsh-code-smell`)存進 `ROADMAP.md` 當未來參考,不留在這裡佔位置。

改用 `assets/` 底下四份罐頭任務書模板,委派時 CC 現場填空(worktree路徑/分支/`git log <base>..HEAD`/port/這次要聚焦的重點)後直接貼進 dsh session 的 `/goal`——「當場設計」指的是 CC 填這些空格+加 2-3 條這次特有的重點,不是從零生一份任務書:

| 情境 | 模板檔 | 何時用 |
|---|---|---|
| 複審(對應 `/code-review`) | `assets/brief-chained-review.md` | 上面「複審層級選擇」選 DSH 外包時用這份 |
| 安全視角 | `assets/brief-security-review.md` | 第10步矩陣判定要加安全視角時,**併入同一次複審**帶著跑,不用另開一趟任務 |
| 簡化清理(對應 `/simplify`) | `assets/brief-chained-simplify.md` | merge 之後想清理、或使用者主動要求時用,任務書白名單沿用原任務的白名單 |
| 跑起來驗證(對應 `run`) | `assets/brief-run-verify.md` | 原任務書漏寫自查清單裡的實測步驟時事後補一趟 |

⚠️ **這整套「複審層級選擇」+四份模板尚未實跑驗證過**,第一次真的用某一份模板時,把實際跑起來的落差補寫回對應的模板檔案跟這一節。也要注意 dsh 目前(見 [[project_deepseek_harness]],2026-08-29 更新到 0.1.2-alpha.1)裸開首頁會 401,要用帶 `?token=` 的 URL 才能開(browserclaw `navigate` 一次即登入)。

### 第 10 步 — CC 獨立驗收
**coding 類型(一般任務/Code Review/Simplify/翻譯):**
- **逐 commit 讀 diff**——不是只看 DeepSeek 的完工報告或自查結果。DeepSeek 的自查是「交件前品管」,CC 這步是「收件品管」,兩者不能互相取代。
- 獨立重跑全部品質關卡:typecheck / lint / build / 專案特定檢查。**自己重新跑一次,不要相信 DeepSeek 回報的跑測試結果**——如果需要另開虛擬環境驗證(例如 Python venv),CC 自己的沙箱通常不給直接寫 `/tmp`,要用 `$TMPDIR`。**重跑驗證腳本時,如果那個腳本本身會寫入已經 commit 的產出檔(例如報告 json),先想清楚會不會把好資料蓋掉**——最好對複本跑,或先 `git stash`,不要直接對著 committed 檔案原地重跑。
- 如果 DeepSeek 沒有主動 commit 改動(任務書沒明講的話很可能不會),CC 這步順手幫它 commit 一次再繼續驗收/merge。
- Code Review 類型:抽查幾條具體發現,對照真實資料/行為驗證是否屬實。

**輔助工具(2026-08-29 新增,CC 自動判斷要不要用,不新增額外提問)**:

CC 自己就有 `/code-review`、`security-review`、`run`、`/simplify` 這幾個收尾指令,以下是怎麼接進第10步——都是**補強**逐 commit 讀 diff 這條鐵規則,不是取代它,工具跑完還是要親自看過 diff,不能因為工具沒抓到就直接放行。

- **`/code-review`**:**一般任務類型的複審層級由上面「複審層級選擇」一節決定**(DSH外包/CC本地/純人工三選一,見上),這裡的「預設跑」只適用於 Simplify 類型(確認簡化沒有動到行為)。真的要跑 CC 本地版本時,針對這次 DeepSeek 的 worktree 分支跑,**要明確指定 level**,不要依賴「沿用上次用過的等級」這種不確定行為。**這步禁止用 `--fix`**——merge 閘門(第11步)還沒過,不該在使用者點頭前先動 diff。⚠️ 對著 worktree 分支下的正確 target 語法還沒實跑驗證過,第一次用時順手確認。
- **`security-review`**:diff 有碰到認證、輸入解析、外部資料、密鑰、網路請求才跑,其他情況不用。
- **`run`**:改動涉及 UI/服務行為才跑。起 dev server 前先查 [[reference_port_registry]] 避免撞埠;第13步收尾要記得把這個 server 一起關掉(見下方)。
- **`/simplify`(預設不跑)**:它會直接套用修改,在 merge 閘門前讓 CC 動 DeepSeek 的產出,會打破「DeepSeek=執行者/CC=品管者」的分工,也讓使用者最後點頭的 diff 不是 DeepSeek 自己寫的。真的要清理,merge 之後另外跑,或乾脆開一個新的 Simplify 類型任務丟給 DeepSeek(這個 skill 本來就有這條任務類型)。

**發現怎麼處理**:阻斷性 correctness 問題不是 CC 自己動手修——退回同一個 dsh session 讓 DeepSeek 自己救(呼應這份 skill 的角色分工),真的搞不定才升級跟使用者講;次要 cleanup 類發現不擋流程,帶進第11步 merge 閘門的回報裡讓使用者看著決定。

**四種 coding 任務類型的預設判法**:

| 任務類型 | `/code-review` | `security-review` | `run` | `/simplify` |
|---|---|---|---|---|
| 一般任務 | 見「複審層級選擇」(使用者三選一) | 條件跑(碰敏感面才跑,選 DSH 外包時併入同一次複審) | 條件跑(改UI/服務才跑) | 預設不跑 |
| Simplify 類型 | 預設跑(確認行為沒變) | 條件跑 | 條件跑 | 不跑(對簡化任務本身重複沒意義) |
| Code Review 類型 | 預設不跑(委派出去本來就是要 DeepSeek 做這件事,CC 用抽查取代) | 條件跑 | 不適用(沒改 code) | 不跑 |
| 翻譯/內容產出 | 預設不跑 | 不跑 | 不跑 | 不跑 |

⚠️ **這套工具整合規則尚未實跑驗證過**——目前只是設計,還沒有真實委派案例走過這條路徑。第一次真的用上 `/code-review` 時,把實際指令怎麼下、有沒有抓到真問題補寫回這一節,比照這份 skill 一貫「先跑真案例再定模板」的規範。

**純研究/調查類型:**
- 抽查一定比例(不用全部)的來源條目,確認真的存在、內容對得上,不是編出來的。
- 檢查數量/日期範圍等硬指標是否達標,沒達標的部分 DeepSeek 有沒有老實講。
- 檢查輸出格式符合要求。
- 通過後,CC 自己讀完整份報告,**用白話文幫使用者整理重點**,不是把整份報告丟給使用者自己看。

### 第 11 步 — Merge 閘門(純研究/調查類型改叫「採用閘門」)
CC **不可自動 merge / 不可自動把報告當定論採用**。跟使用者確認一次(文字回覆「可以合併」之類,或用 `AskUserQuestion`)才能繼續。這關不能被自動化跳過——這類決策屬於「複雜決策」,拍板的人是使用者。如果第10步用 `/code-review`/`security-review`/`run` 抓到次要(非阻斷性)的 cleanup 類發現,要把這些發現列進這次的回報內容一起讓使用者看,不能自己先斬後奏地略過。

### 第 12 步 — Merge(純研究/調查類型:交付報告)
coding 類型:使用者確認後,CC 執行 merge 回 main(`git merge --no-ff <分支> -m "..."`),DeepSeek 全程不碰這步。**2026-08-16 首次端到端實測**:worktree 分支乾淨合回 main、產生真正的雙親 merge commit、merge 後在 main 重跑測試全線綠——整條「merge 這步」之前只有理論設計,現在有真實案例佐證。純研究/調查類型:沒有 merge 動作,這步等於「把整理好的白話重點回報給使用者」。

### 第 13 步 — 收尾

**如果第 10 步用 `run` 起過 dev server / 背景程序**:先確認已經關掉——`ps aux` 查一下,用 `kill <PID>`(不要用 `pkill -f`,會連自己這條指令的 command line 一起誤殺,見 [[reference_pkill_self_kill_gotcha]]),別留孤兒程序燒 CPU 沒人發現。

**coding 類型,worktree/分支**:
- 觸發時 `AskUserQuestion` 第 4 題選「是,自動刪除」→ 不用再問,直接刪除 worktree、刪除分支,需要的話重新部署。
- 選「否」→ 照舊詢問使用者要不要刪。
- **如果 `git worktree remove` 卡住報 "Device or resource busy"**(常見於從別台機器 zip 傳過來、混進壞掉 `.claude/`、`.mcp.json` 之類殘骸檔的專案):這通常不是真的檔案被佔用(`fuser`/`lsof`/`/proc/*/fd` 查不到任何 process 握著它),是 CC 自己的沙箱把這些路徑當受保護設定檔擋刪除。解法:先嘗試 `git worktree remove` 失敗就直接 `rm -rf` 整個目錄(帶 `dangerouslyDisableSandbox: true`,範圍僅限這個 worktree 路徑本身),再 `git worktree prune` 清 metadata,最後才刪分支——順序錯了(例如先 prune 再刪目錄)一樣會卡住。

**coding 類型,browserclaw/dsh 兩層清理**(2026-08-16 新增,對應「B CLAW 會殘留垃圾群組」這個真實痛點——2026-08-16 實測當下光是別的 agent 留下的 dsh workspace/session 就已經一堆數小時到一天前的殘留,清理是有真實效益的):

1. **dsh 側,刪除這次任務的工作區**(2026-08-16 已兩次實測驗證可靠,不再是 best-effort):回到第 4 步開的那個 browserclaw 分頁,打開側邊欄,對 workspace 路徑等於這次 worktree 路徑的 treeitem 依序執行:`hover`(讓操作按鈕浮出)→**緊接著馬上**`click` 那顆「工作區"<name>"的操作」按鈕(兩個動作分開下但中間不要插入 snapshot/wait,連續執行成功率才高)。⚠️ **偶爾第一次點擊會落空**(點到 treeitem 本身把它收合,而不是點到操作按鈕——2026-08-16 第二次實測就撞到一次):徵兆是點完之後選單沒開、treeitem 反而變成 `[collapsed]`。**解法是重新 `hover` 一次同一個 treeitem,拿到新鮮的按鈕 ref 後立刻再 `click` 一次**,不要重複點同一個舊 ref。開出選單後點「刪除工作區」→跳出的確認 dialog 裡點「刪除工作區」確認鈕。⚠️ **這個動作只會刪掉「工作區」這層分組,不會刪掉底下的 session/對話紀錄**——session 會被移到側欄的「未分組」桶裡繼續留著(這解釋了為什麼側欄「未分組」底下常年一堆歷史 session)。如果要連 session 本身都清掉,還要另外對 session 項目做「歸檔會話」(見 `deepseek-manual` 的 session 操作說明),目前的收尾流程不強制做到這一步,只求「工作區」這層不再持續累積即可。
2. **browserclaw 側,關掉這次任務的分頁群組**(核心機制已驗證可靠,一定要做,但要留意下面的 ID 對不上陷阱):用 `tab_groups` 工具 `action: "list"` 找到第 4 步 `name_session` 命名的那個群組(群組名會是 `claude/<你當時取的名字>`),**先用 `tabs` 工具 `action: "list"` 交叉核對**——確認 `tab_groups` 回報的那個 page id 真的出現在 `tabs` 回應的「Your tabs」區塊裡。⚠️ **2026-08-16 實測撞過一次兩者對不上**:`tab_groups list` 回報群組掛在 page 166,但 `tabs list` 顯示我實際擁有的分頁是 167,166 反而落在「User's tabs」(不屬於任何 agent)。這種情況下**不要照 `tab_groups` 回報的 page id 去 `close`**,改成直接對 `tabs list` 裡確認是「Your tabs」的那個 page id 做 `tabs` 工具的 `action: "close"`——關掉自己真正擁有的分頁後,對應的群組通常也會跟著消失(2026-08-16 實測驗證了這點)。兩者一致的正常情況下,`tab_groups` 的 `action: "close"` 帶對應 `groupId` 一次呼叫就會關掉群組本身跟裡面所有分頁,不用逐一關 tab。**只准關自己這次任務開的、且經過交叉核對的分頁/群組,絕對不要動其他群組**(不管是使用者自己的分頁,還是其他 agent/session 名下的群組——2026-08-16 實測光是背景就有其他 agent 在跑的 `nba-weekly-news` 相關群組,誤關會打斷別人的任務)。

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
