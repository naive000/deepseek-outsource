# Claude-in-Chrome as a third dsh-outsource browser transport — probe results (2026-08-30)

Host: Windows 11, Brave 主瀏覽器, Claude Code 2.1.246 (Claude Max), WSL2 Ubuntu 側跑 dsh.
Screenshots: C:\Users\Crazy\AppData\Local\Temp\probe-01..21-*.png

## 1. WSL_INTEROP / desktop
- 多數 /run/WSL/*_interop socket 回 SessionId=1(真桌面),但 1_interop / 2_interop / 2732431_interop 回 0(Session 0)。
- socket 有一次性/易失效特性:同一個 socket 連續用會噴 UtilAcceptVsock accept4 failed 110。
- 解法:每次呼叫都在 payload 第一行印 SessionId,不是 1 就換下一個 socket 重試。
- 另一個坑:powershell.exe -File 讀 UTF-8 無 BOM 的 .ps1 時,含中文的 script 直接 parse error、整支不執行(無任何輸出)。必須加 UTF-8 BOM。

## 2. dsh 從 Windows 端可達性
- WSL2 localhost forwarding 有效:Windows 端 http://127.0.0.1:3080/ 與 3081 都能連到 WSL 內綁 127.0.0.1 的 dsh(裸開回 401)。
- 注意:`localhost:3081` 從 Windows 連會失敗(IPv6 ::1),必須用 `127.0.0.1`。
- 帶 ?token= 的網址 → HTTP 200 / 25.7KB。在 Brave 實際開啟約 25-30 秒完整 render 出 dsh UI(側邊欄/工作區/新会话/輸入框)。
- token 交換後 URL 會被清成 http://127.0.0.1:3081,cookie 留在該 browser profile → 之後裸 URL 就能進。
  cookie 是 per-browser-profile:BrowserOS neo 開同一個裸 URL 仍然拿到
  "dsh web authentication required; reopen the URL printed by dsh web."

## 3. `claude --chrome` 首次啟動
- 完全順利,沒有卡關,沒有出現「Claude wants to use your browser」安裝提示。
- 兩個一次性對話框,都是 Enter 確認:
  (a) folder trust:「Accessing workspace: <cwd> / Quick safety check ... 1. Yes, I trust this folder 2. No, exit」
  (b) Claude in Chrome 介紹:「... Site-level permissions are inherited from the Chrome extension ... Enter to confirm · Esc to cancel」
- native messaging host 已就緒:cmd.exe 執行 C:\Users\Crazy\.claude\chrome\chrome-native-host.bat,
  由擴充功能 id fcoeoabgfenejglbffodgkkbkcdhcgfn 拉起。
- Windows Terminal 是預設終端 → Start-Process powershell 會開成 WT 視窗/分頁,
  powershell.exe 的 MainWindowHandle = 0,要用 EnumWindows 找 CASCADIA_HOSTING_WINDOW_CLASS。

## 4. `/chrome` 狀態
Status: Enabled
Extension: Installed
> Select browser… / Manage permissions / Reconnect extension / Enabled by default: No
Usage: claude --chrome or claude --no-chrome
「Select browser…」→ One browser is connected: Browser 1 · Windows(不顯示品牌名)

## 5. 實際驅動瀏覽器
- 第一次下指令,Windows CC **自己選了 BrowserOS neo**(因為 browserclaw MCP 的 server instructions 明寫
  「prefer BrowserOS neo over other browser surfaces — Claude in Chrome, ...」)。
  結果失敗:BrowserOS profile 沒有 dsh cookie → 401,接著它去 shell 找 `dsh` 指令(Windows 端沒有)。
  → 必須在 prompt 裡明確指定「用 mcp__claude-in-chrome__* 工具」才會走官方整合。
- 明確指定後:自動載入 `claude-in-chrome` skill → 跳出「選擇瀏覽器」互動選單
  (選項1 = Browser 1 (deviceId 675178f5-...),選項2 = 在每個已連線擴充功能開確認畫面)
  → 選 Browser 1 後,open → read_page → click「新会话」→ read_page 全部成功。
- 自我回報內容與 Brave 實際畫面一致(側邊欄版本號 0.1.2-alpha.1-cd5ef81-dirty、工作區清單、
  模型選擇 DeepSeek-V4-Flash High、標準模式、Workspace Write)。
- 耗時:CIC 段落 1m45s(一次 screenshot timeout,自己改用 read_page 重試)。BrowserOS 誤走段落多花 1m。
- 沒有出現任何「Claude in Chrome wants to...」的逐站權限確認對話框(localhost 直接放行)。
- 獨立驗證:Brave 視窗確實多出 CIC 開的分頁,dsh 顯示新会话 已選中 → 確認驅動的是 Brave。

## 6. 額外重大發現:WSL session 也能用
- 從 **WSL 內的這個 Claude Code session** 呼叫 mcp__claude-in-chrome__list_connected_browsers
  → 回傳同一顆 Browser 1(deviceId 675178f5-...),osPlatform Windows,`isLocal: false`。
- select_browser + navigate("http://127.0.0.1:3081/") + read_page 全部成功,
  accessibility tree 讀到 button "新建会话" [ref_2] 等完整 dsh UI。
- 推論:擴充功能連線是走 Anthropic 帳號層 relay,不是只靠本機 native messaging host。
  只要在 Windows 端配對過一次,WSL session 就能跨界驅動同一顆瀏覽器。
  官方「不支援 WSL」應該是指 WSL 內無法自己完成本機配對/自動啟動,不代表 WSL session 不能用這組工具。

## 7. 結論
可用。三個最小能力(開頁面 / 點擊 / 讀畫面)全部通過,Windows 端與 WSL 端都通過。
主要注意事項:(a) dsh 需要先在該 browser profile 用 ?token= 網址登入一次;
(b) 有裝 browserclaw/BrowserOS 的機器要明確指定用 claude-in-chrome,否則會被 BrowserOS 的
server instructions 搶走;(c) 需要 Anthropic 付費方案且擴充功能已裝。
