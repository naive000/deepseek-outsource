#!/usr/bin/env bash
# dsh-web.sh — dsh web(DeepSeek harness 網頁服務,127.0.0.1:3080)的 PM2 常駐控制腳本。
#
# 用法:
#   dsh-web.sh status    # 一行摘要:有沒有在聽、pid、是 pm2 管的還是裸跑、http 狀態、session 數(掛掉 exit 1)
#   dsh-web.sh ensure    # 沒在聽就用 pm2 拉起來(有 flock 防多 session 同時拉);已在聽就靜默 exit 0
#   dsh-web.sh start     # 同 ensure,但會印過程
#   dsh-web.sh restart   # pm2 restart(只對 pm2 管的;裸跑的請用 adopt)
#   dsh-web.sh stop      # pm2 stop(手動停掉後 ensure 不會自動再拉,要自己 start)
#   dsh-web.sh logs [N]  # 最近 N 行 pm2 log(預設 40,token 打碼)
#   dsh-web.sh url       # 印出最新一次啟動 log 裡帶 ?token= 的完整網址(給 browserclaw navigate 用)
#   dsh-web.sh adopt --yes   # 把目前裸跑的 dsh web 平滑換成 pm2 管:SIGTERM 舊的 → 等 port 釋放 → pm2 start → 比對 session 數
#
# 為什麼(2026-09-11 事故):dsh web 原本是 CC Bash run_in_background 裸跑的,oom_score_adj=200,
# 記憶體吃緊時被 OOM killer 優先砍掉,6 個委派任務要人工摸索恢復。詳見
# ~/.claude/skills/deepseek-outsource/SKILL.md「dsh 服務中斷復原」。
#
# 規矩:
# - pm2 一律用絕對路徑 v7.0.1(跟 daemon 同版)。不要用 npx pm2(7.0.4):client/daemon 版本不合會
#   觸發 daemon 更新重啟,影響底下所有 pm2 app。
# - 從 Claude Code Bash tool 呼叫時要 dangerouslyDisableSandbox:sandbox 內連不到 127.0.0.1,
#   也連不到 pm2 的 unix socket,會誤判成「掛了」。
# - 這支腳本自己不會 kill 任何裸跑 process,只有 adopt --yes 會,而且會先確認那個 pid 真的是 dsh web。
set -u

PM2=/home/crazy/.nvm/versions/node/v24.15.0/bin/pm2
CURL=/usr/bin/curl
JQ=/usr/bin/jq
APP=dsh-web
PORT=3080
ECO=/home/crazy/deepseek-game/ecosystem.dsh-web.config.cjs
LOG_OUT=/home/crazy/.pm2/logs/${APP}-out.log
STATE_DIR=/home/crazy/.claude/tmp/dsh-web
LOCK="$STATE_DIR/ensure.lock"
SESS_DIR=/home/crazy/.dsh/sessions
READY_TIMEOUT=${DSH_WEB_READY_TIMEOUT:-90}

mkdir -p "$STATE_DIR" 2>/dev/null

http_code() { "$CURL" -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000; }
listen_pid() { ss -ltnpH "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1; }
pm2_field() { "$PM2" jlist 2>/dev/null | "$JQ" -r --arg n "$APP" ".[]|select(.name==\$n)|$1" 2>/dev/null; }
pm2_status() { pm2_field '.pm2_env.status'; }
pm2_pid() { pm2_field '.pid'; }
session_count() { find "$SESS_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }
# 401(未帶 token)/200/30x 都算就緒;404 是開機中(靜態層先起、API 層還在載 plugin);000 是沒在聽。
is_ready_code() { case "$1" in 401|200|30[0-9]) return 0;; *) return 1;; esac; }

wait_ready() {
  local t=0 code=000
  while [ "$t" -lt "$READY_TIMEOUT" ]; do
    code=$(http_code)
    if is_ready_code "$code"; then echo "$code"; return 0; fi
    sleep 1; t=$((t+1))
  done
  echo "$code"; return 1
}

owner_kind() {  # 印 pm2 / bare / none
  local lp; lp=$(listen_pid)
  [ -z "$lp" ] && { echo none; return; }
  local pp; pp=$(pm2_pid)
  [ -n "$pp" ] && [ "$pp" = "$lp" ] && { echo pm2; return; }
  echo bare
}

cmd_status() {
  local lp code kind st rs up
  lp=$(listen_pid); code=$(http_code); kind=$(owner_kind)
  st=$(pm2_status); rs=$(pm2_field '.pm2_env.restart_time'); up=$(pm2_field '.pm2_env.pm_uptime')
  local ready="booting"; is_ready_code "$code" && ready="ready"; [ "$code" = "000" ] && ready="DOWN"
  local upstr="-"
  if [ -n "$up" ] && [ "$up" != "null" ]; then upstr="$(( ( $(date +%s%3N) - up ) / 60000 ))m"; fi
  if [ -n "$lp" ]; then
    echo "dsh-web: LISTENING pid=$lp owner=$kind http=$code ($ready) oom_adj=$(cat /proc/$lp/oom_score_adj 2>/dev/null || echo ?) rss=$(( $(awk '/VmRSS/{print $2}' /proc/$lp/status 2>/dev/null || echo 0) / 1024 ))MB"
  else
    echo "dsh-web: DOWN (nothing listening on 127.0.0.1:$PORT)"
  fi
  echo "pm2 app '$APP': ${st:-not registered} restarts=${rs:-–} uptime=$upstr  | sessions on disk: $(session_count) files under $SESS_DIR"
  [ -n "$lp" ]
}

pm2_daemon_alive() {  # 只在 God Daemon 已經活著時才動手:從 hook/未知 env 把 daemon 拉起來,daemon 會繼承那個 env 跟 oom_score_adj
  local dp; dp=$(cat /home/crazy/.pm2/pm2.pid 2>/dev/null)
  [ -n "$dp" ] && kill -0 "$dp" 2>/dev/null
}

pm2_bring_up() {  # 內部:依 pm2 狀態決定 start / restart;回傳 0=有動作,3=手動停止不動,2=失敗
  pm2_daemon_alive || { echo "pm2 God Daemon is DOWN (pid file /home/crazy/.pm2/pm2.pid) → not starting it from here; bring pm2 back from a normal shell (crontab @reboot pm2 resurrect / '$PM2 resurrect') first"; return 2; }
  local st; st=$(pm2_status)
  case "$st" in
    "")
      echo "pm2: '$APP' not registered → pm2 start $ECO"
      ( cd /home/crazy/deepseek-game && "$PM2" start "$ECO" >/dev/null 2>&1 ) || { echo "pm2 start failed"; return 2; }
      ;;
    stopped)
      echo "pm2: '$APP' is STOPPED (manual stop) → not auto-starting. Run: $0 start"
      return 3
      ;;
    online|launching|waiting\ restart)
      echo "pm2: '$APP' is $st but port $PORT not answering → letting pm2 finish (or restart if it stays dead)"
      ;;
    *)
      echo "pm2: '$APP' is $st → pm2 restart $APP"
      "$PM2" restart "$APP" >/dev/null 2>&1 || { echo "pm2 restart failed"; return 2; }
      ;;
  esac
  return 0
}

# 2026-09-11 拿掉自動 pm2 save(見 cmd_ensure / cmd_start):使用者要的是「CC 要用時沒開/斷線
# 才觸發啟動」,不是「開機自動啟動」。pm2 save 會把現在活著的清單整個蓋進 dump.pm2,而這台機器
# 已有 crontab `@reboot pm2 resurrect`——一旦存過一次,dsh-web 就會變成每次真的重開機都自動起來,
# 跟 ensure/start 的「隨選」語意矛盾。所以 dsh-web 刻意**不**進開機清單:pm2 daemon 活著時的
# autorestart(見 ecosystem 設定)已經涵蓋「跑到一半掛掉自動拉起」;真的整台重開機後,dsh-web
# 就是單純沒在跑,直到下一次 hook/CC 真的要用它時才被 ensure 起來——這正是要的行為。
# 留著這支函式(未使用)給日後如果真的要手動 opt-in 進開機清單時用,不要在 ensure/start 裡自動呼叫。
pm2_save_with_backup() {  # 手動 opt-in 用;正常流程不會呼叫
  local bak; bak="/home/crazy/.pm2/dump.pm2.bak-dsh-web-$(date +%Y%m%d-%H%M%S)"
  [ -f /home/crazy/.pm2/dump.pm2 ] && cp -p /home/crazy/.pm2/dump.pm2 "$bak" 2>/dev/null
  "$PM2" save >/dev/null 2>&1 && echo "pm2 save done (dump.pm2 updated for @reboot resurrect; previous copy: $bak)"
}

cmd_ensure() {  # 靜默版:已在聽 → exit 0 不印;沒在聽 → 拉起、等就緒、印一行結果
  exec 9>"$LOCK"
  flock -w 120 9 || { echo "ensure: could not acquire lock"; return 2; }
  local lp; lp=$(listen_pid)
  [ -n "$lp" ] && return 0
  local rc; pm2_bring_up; rc=$?
  [ "$rc" = 3 ] && return 3
  [ "$rc" = 2 ] && return 2
  local code; code=$(wait_ready) && {
    echo "ensure: dsh-web is up (pid=$(listen_pid) http=$code)"
    # 刻意不 pm2 save:這是隨選/自動觸發的啟動(hook 或人工都可能叫到這條),不代表「要進開機清單」。
    return 0
  }
  echo "ensure: dsh-web still not ready after ${READY_TIMEOUT}s (http=$code); check: $0 logs"
  return 1
}

cmd_start() {
  local lp; lp=$(listen_pid)
  if [ -n "$lp" ]; then
    echo "already listening: pid=$lp owner=$(owner_kind)"
    [ "$(owner_kind)" = bare ] && echo "(bare process — 要換成 pm2 管請用: $0 adopt --yes)"
    return 0
  fi
  local rc; pm2_bring_up; rc=$?
  [ "$rc" != 0 ] && return "$rc"
  local code; code=$(wait_ready) || { echo "not ready after ${READY_TIMEOUT}s (http=$code); see: $0 logs"; return 1; }
  echo "up: pid=$(listen_pid) http=$code"
  # 刻意不 pm2 save,理由同 cmd_ensure。
  cmd_url
}

cmd_restart() {
  local kind; kind=$(owner_kind)
  case "$kind" in
    pm2) "$PM2" restart "$APP" >/dev/null 2>&1; local code; code=$(wait_ready) || { echo "restart: not ready (http=$code)"; return 1; }; echo "restarted: pid=$(listen_pid) http=$code"; cmd_url;;
    bare) echo "refusing: current dsh web (pid=$(listen_pid)) is a bare process, not pm2-managed. Use: $0 adopt --yes"; return 2;;
    none) echo "nothing listening; use: $0 start"; return 1;;
  esac
}

cmd_stop() {
  [ "$(owner_kind)" = pm2 ] || { echo "refusing: dsh web is not pm2-managed (owner=$(owner_kind))"; return 2; }
  "$PM2" stop "$APP" >/dev/null 2>&1 && echo "stopped (pm2 status=stopped; ensure will NOT auto-start it — use '$0 start')"
}

cmd_logs() {
  local n=${1:-40}
  [ -f "$LOG_OUT" ] || { echo "no pm2 log yet ($LOG_OUT missing) — dsh web has never run under pm2"; return 1; }
  "$PM2" logs "$APP" --nostream --lines "$n" 2>/dev/null | sed 's/token=[A-Za-z0-9_-]*/token=<redacted, see: dsh-web.sh url>/g'
}

cmd_url() {
  if [ "$(owner_kind)" = bare ]; then
    echo "url: dsh web is a bare process; its ?token= URL was only printed to the shell that launched it."
    echo "     Same browser profile usually still has the persisted auth cookie → plain http://127.0.0.1:$PORT/ works; if you get 401, adopt to pm2 first."
    return 1
  fi
  [ -f "$LOG_OUT" ] || { echo "url: no pm2 log yet"; return 1; }
  local line; line=$(grep 'dsh web: http' "$LOG_OUT" | tail -1)
  [ -n "$line" ] || { echo "url: banner not printed yet (still booting?)"; return 1; }
  echo "url: $(echo "$line" | sed -n 's/.*dsh web: \(http[^ ]*\).*/\1/p')"
}

cmd_adopt() {
  [ "${1:-}" = "--yes" ] || { echo "adopt kills the current bare dsh web (in-flight DeepSeek turns get interrupted; session state on disk survives). Re-run with: $0 adopt --yes"; return 2; }
  local kind; kind=$(owner_kind)
  [ "$kind" = bare ] || { echo "nothing to adopt (owner=$kind)"; return 1; }
  local lp; lp=$(listen_pid)
  local cmdline; cmdline=$(tr '\0' ' ' < "/proc/$lp/cmdline" 2>/dev/null)
  case "$cmdline" in *"apps/cli/src/bin.ts web"*) ;; *) echo "refusing: pid $lp on :$PORT is not dsh web ($cmdline)"; return 2;; esac
  local before; before=$(session_count)
  echo "adopt: sessions on disk before = $before; SIGTERM pid $lp (dsh graceful window 5s) ..."
  kill -TERM "$lp" 2>/dev/null
  local t=0; while [ "$t" -lt 20 ] && kill -0 "$lp" 2>/dev/null; do sleep 1; t=$((t+1)); done
  if kill -0 "$lp" 2>/dev/null; then echo "adopt: still alive after 20s → SIGKILL"; kill -KILL "$lp" 2>/dev/null; sleep 1; fi
  [ -z "$(listen_pid)" ] || { echo "adopt: port $PORT still held; aborting"; return 2; }
  cmd_start || return $?
  echo "adopt: sessions on disk after = $(session_count) (before $before) — 打開 browserclaw 新分頁,側欄找回 session,進行中的任務點「恢復目標」。"
}

case "${1:-status}" in
  status) cmd_status;;
  ensure) cmd_ensure;;
  start) cmd_start;;
  restart) cmd_restart;;
  stop) cmd_stop;;
  logs) cmd_logs "${2:-40}";;
  url) cmd_url;;
  adopt) cmd_adopt "${2:-}";;
  *) sed -n '2,12p' "$0"; exit 2;;
esac
