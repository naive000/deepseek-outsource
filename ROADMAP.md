# deepseek-outsource 開發路線圖

> ⚠️ **非固定路線圖**:以下版本號、順序、內容都只是目前的規劃草稿,不是承諾。實跑過程中發現優先級該調整、某版該拆分或合併、甚至整個方向要改,隨時直接改這份文件,不用照表操課。

目前狀態:**MVP 2.0**(2026-08-16 完整跑通一次,詳見下方)。

這份是草稿,順序跟優先級可以隨時調整——每完成一階段,回來把這份文件的狀態更新掉。

## MVP 1.0 — 核心骨架(已完成)
- 4 種任務類型(一般任務/Code Review/Simplify/翻譯內容),都有今晚真實案例佐證
- 完整 14 步 SOP:討論範圍→worktree→brief→browserclaw dispatch→監控→驗收→merge 閘門→收尾
- 三條鐵規則:DeepSeek 不碰 main、diff+merge 100% CC 處理、merge 前使用者必須點頭
- 尖峰時段檢查(北京/台灣時間 09-12、14-18 命中就問)
- Browserclaw 已知陷阱清單

## MVP 2.0 — 首次實戰驗證(已完成,2026-08-16 離峰時段)
- 測試任務:throwaway sandbox repo(`deepseek-test-sandbox`)+ 字串反轉函式 + pytest 測試,「一般任務」類型
- **14 步全部走完,流程本身是通的**:worktree 隔離 → 任務書 → browserclaw dispatch → 監控 → CC 獨立驗收(自己重跑 pytest,沒有照單全收 DeepSeek 的自查結果)→ merge 閘門(使用者點頭)→ merge → 收尾清 worktree/分支
- 撞到的坑跟落差,已經回頭修進 SKILL.md 跟 brief-template.md:
  - 斷線重連後開新分頁,不保證恢復到原本監控的 session(要靠側邊欄手動找)
  - `/goal` 送出後輸入框不清空,是正常現象
  - 任務書沒明講要 commit,DeepSeek 完工後檔案是 untracked 狀態——已補進範本
  - 測試工具(pytest)會在白名單外留下 `.pytest_cache/`、`__pycache__/`,DeepSeek 這次有自己抓到並清理,但範本也補了提醒
  - CC 自己驗收時另開 venv 測試,踩到 CC 自己沙箱的 `/tmp` 唯讀限制,要改用 `$TMPDIR`
  - `.claude/.cc-writes/` 空目錄是沙箱基礎設施產物,不是 DeepSeek 動的,已記錄避免下次重新調查
- 沒驗證到的部分:任務完成得很快,10 分鐘輪詢只觸發過一次就已完工,所以「還在執行中的任務怎麼監控」這件事還是沒有真實案例——留給下一次跑比較大的任務時補

## MVP 3.0 — 第五種任務類型:純研究/調查(2026-08-16 設計完成,即將首次實跑)
- 真實案例出現:使用者用觸發語「交給 deepseek 整理」丟了一個 NBA 新聞彙整任務,發現現有 4 種類型完全不適用
- 已補進 SKILL.md:任務類型表新增第五列、跳過 worktree 改用純輸出資料夾、專屬自查清單、驗收/merge 閘門改成「抽查來源真實性+採用閘門」
- 待補:實跑一次確認設計真的可行(輸出資料夾隔離夠不夠、DeepSeek 的 web search 工具好不好用、抽查來源真實性這件事在 CC 這端怎麼做最有效率)

## 2026-08-16 第二輪優化(觸發問法+權限+自動清理+5分鐘監控+使用記錄)— 已全部實跑驗證

同日稍晚用一個真實 probe 任務(worktree 內改檔+commit)補完了當時卡住的 3 項驗證:dsh 工作區刪除選單可靠開啟方式已確認、mid-task 升級提示證實在 Workspace Write 檔位下對 commit 相關情境會自動秒過不用人點、worktree 用真實 `/home/crazy` 路徑沒問題(先前卡住是服務過載)。細節見 `PENDING-VERIFICATION.md`。

使用者直接指定 5 個優化項目,先用 `advisor()` 討論設計、再實測 browserclaw 收集真實資料補足未知數,才落地進 SKILL.md:

1. **使用次數記錄**:每次觸發/收尾各 append 一筆 JSONL 到 `usage-log.jsonl`(已加 `.gitignore`),為 MVP 9.0 花費追蹤鋪路。⚠️ 發現 CC sandbox 擋 `bash echo >>` 寫進 `~/.claude/skills/`,skill 裡已註明要用 `Write`/`Edit` 工具寫,不能用 bash。
2. **Write / Full access 加入詢問**:觸發時的單次 `AskUserQuestion` 從 2 題擴成 4 題,權限檔位(第 3 題)不再是「預設 Workspace Write 不問、只有 Full access 才問」,三檔都攤開讓使用者明確選一次。
3. **Merge 後自動刪除 worktree**:新增第 4 題「是否自動刪除」,預設「是」;選了「是」第 13 步不再二次詢問。
4. **監控間隔 10→5 分鐘,並加自動核准升級提示**:字面上是「看到授權提示就直接按確定」,但落地時加了範圍收斂——只自動核准提示目標在 worktree 內、或符合已知的 git commit escalate 模式的請求,範圍外一律照鐵規則停下來問使用者。這個收斂有在報告裡跟使用者說明,是主動聲明的判斷,不是偷偷加的限縮。⚠️ 這個提示實際 UI 長怎樣還沒實測到,見 `PENDING-VERIFICATION.md`。
5. **收尾兩層清理**:coding 類型第 13 步新增 dsh 工作區刪除(best-effort,選單點擊今天沒點開,原因未知)+ browserclaw `tab_groups` 群組關閉(已驗證可靠,一次呼叫關群組+全部分頁)。只准動自己這次任務開的群組。

**探測過程中的意外插曲**:第一次搭建 throwaway probe repo 時,腳本裡的 `mkdir`/`cd` 因為目標目錄(`$CLAUDE_JOB_DIR/tmp`)唯讀而失敗,但 `set -e` 沒有真的中止腳本(推測跟 bash 工具的 cwd 重置機制有關),導致後面的 `git init`/`git commit` 意外落在使用者真正的專案 repo(`local_Tradview`)裡,建了一個不該存在的 commit 跟分支。當下立刻用 `git update-ref -d refs/heads/main` + `git reset` 復原成 unborn HEAD、跟原本一模一樣的乾淨狀態,並老實跟使用者報告這個失誤——之後所有需要真實 host 路徑的 scratch 操作一律先確認 `pwd`/測試路徑可寫,不再假設多行腳本裡的 `cd` 失敗會讓後續指令連帶失敗。

## MVP 4.0 — 離峰排程自動化
- 目前選「排到離峰」之後,使用者要自己記得再手動觸發一次
- 補一個排程機制(cron 或 ScheduleWakeup),離峰時段到了自動幫使用者把暫存的任務送出去
- 需要先想清楚:暫存的任務書放哪裡、怎麼避免時間到了但使用者已經不需要這任務了

## MVP 5.0 — 跟「deepseek harness 說明書」skill 對接
- 另一個平行在做的 skill(dsh 網頁 UI 操作手冊)完成後,把細節性的斜線指令行為改成引用那份文件
- 這裡只留「委派流程需要知道的」,避免兩份文件重複維護同一份細節

## MVP 6.0 — 監控從輪詢升級
- 2026-08-16:輪詢間隔從 10 分鐘縮到 5 分鐘(見上方「第二輪優化」),但本質還是輪詢,不是事件觸發——下面兩點仍是待辦
- 目前是固定 5 分鐘輪詢看畫面
- 研究 dsh 有沒有 webhook / API / 完工通知機制,能不能改成事件觸發而非輪詢
- 如果沒有,至少把輪詢做成背景 Monitor 而不是佔用主線程等待

## MVP 7.0 — 多任務併發管理
- 目前設計是一次委派一個任務
- 需求出現時(同時想分包好幾個獨立任務),補上追蹤多個 worktree/session 狀態的機制,避免搞混

## MVP 8.0 — 驗收輔助自動化
- 幫 CC 自己產生 diff 摘要、自動跑 typecheck/lint/build 品質關卡的腳本化
- 減少人工判斷的重複勞動,但**merge 拍板權限仍保留給使用者**,這條鐵規則不因自動化而鬆動

## MVP 9.0 — 花費追蹤
- 2026-08-16:`usage-log.jsonl`(見上方「第二輪優化」第 1 項)已經開始記每次觸發/收尾的 task_type、target、outcome、offpeak——目前只是原始記錄,還沒做成統計/報表
- 記錄每次委派實際花了多少 token / 多少錢,分尖峰/離峰累計
- 讓使用者能看到「分包給 DeepSeek」這件事實際的成本效益,而不是憑感覺

## MVP 10.0 — 跨專案模板庫
- 累積多個專案跑過的 brief 範本、白名單黑名單慣例
- 形成可重用的 per-repo 設定檔,減少每次委派都要從零討論範圍

---

## 使用方式
每次要推進下一階段,直接跟 CC 說「deepseek-outsource 要做 MVP N」,CC 會照這份規劃走,做完更新這份文件的狀態並 commit。
