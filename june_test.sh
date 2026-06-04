#!/bin/sh
set -u

#################################################
# MINING AGENT — CPU + GPU (KRYPTEX)
# TELEGRAM + АВТОНОМНАЯ УСТАНОВКА
# РАБОТАЕТ В DOCKER / MINIMAL / ANY LINUX
#################################################

[ "${ALLOW_MINING:-0}" = "1" ] || exit 0

# ----- ВЕРСИЯ БЕЗ WGET, CURL, CRONTAB -----
# ----- FALLBACK: ЕСЛИ КОМАНДЫ НЕТ - ПРОПУСК -----

HOST="$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname 2>/dev/null || echo unknown)"
INTERVAL=30

# ===== ACCOUNTS =====
KRIPTEX="krxX3PVQVR"

# ===== POOLS =====
XMR_POOL="xmr.kryptex.network:7029"
ETC_POOL="etc.kryptex.network:7033"

# ===== TELEGRAM =====
TG_TOKEN="8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g"
TG_CHAT="6629912606"
TG_API="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

tg() {
  _msg="$1"
  [ -z "$_msg" ] && return
  _msg=$(printf "%s" "$_msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
  curl -s --connect-timeout 10 -X POST "$TG_API" -d chat_id="$TG_CHAT" --data-urlencode text="$_msg" >/dev/null 2>&1 || true
}

# ===== PATHS =====
BASE="$HOME/.mining"
BIN="$BASE/bin"
RUN="$BASE/run"
LOG="$BASE/log"
mkdir -p "$BIN/cpu" "$BIN/gpu" "$RUN" "$LOG" 2>/dev/null || true

# ===== ПРОВЕРКА КОМАНД: curl, tar, id =====
for cmd in curl tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    tg "❌ [$HOST] Отсутствует $cmd — установка невозможна"
    exit 1
  fi
done

tg "🚀 [$HOST] Старт установки майнинга"

#################################################
# УНИВЕРСАЛЬНЫЙ УСТАНОВЩИК
# (распаковывает бинарник из любого TAR.GZ)
#################################################
_install_bin() {
  _url="$1"
  _target_dir="$2"
  _target_bin="$3"
  _name="$4"

  _tmp="/tmp/install_$$_$_name.tar.gz"
  curl -fL --connect-timeout 10 --max-time 60 "$_url" -o "$_tmp" || return 1
  tar -xzf "$_tmp" -C /tmp || return 1
  # ищем бинарник в распакованном дереве
  _bin_path=$(find /tmp -type f -executable -name "$_target_bin" | head -1)
  if [ -z "$_bin_path" ]; then
    rm -rf "$_tmp" /tmp/install_*_$_name
    return 1
  fi
  cp "$_bin_path" "$_target_dir/$_target_bin"
  chmod +x "$_target_dir/$_target_bin"
  rm -rf "$_tmp" /tmp/install_*_$_name
  return 0
}

#################################################
# INSTALL XMRig
#################################################
install_xmrig() {
  tg "📦 [$HOST] Установка XMRig"
  pkill xmrig 2>/dev/null || true
  rm -f "$BIN/cpu/xmrig"
  if _install_bin \
    "https://github.com/kryptex-miners-org/kryptex-miners/releases/download/xmrig-6-26-0/xmrig-6.26.0-linux-static-x64.tar.gz" \
    "$BIN/cpu" "xmrig" "xmrig"
  then
    tg "✅ [$HOST] XMRig установлен"
    return 0
  else
    tg "❌ [$HOST] XMRig НЕ УСТАНОВЛЕН"
    return 1
  fi
}

#################################################
# INSTALL lolMiner
#################################################
install_lolminer() {
  tg "📦 [$HOST] Установка lolMiner"
  pkill lolMiner 2>/dev/null || true
  rm -f "$BIN/gpu/lolMiner"
  if _install_bin \
    "https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz" \
    "$BIN/gpu" "lolMiner" "lolminer"
  then
    tg "✅ [$HOST] lolMiner установлен"
    return 0
  else
    tg "❌ [$HOST] lolMiner НЕ УСТАНОВЛЕН (возможно, нет GPU?)"
    return 1
  fi
}

#################################################
# ЗАПУСК
#################################################
start_cpu() {
  pkill -f "xmrig.*--http-port 16000" 2>/dev/null || true
  rm -f "$RUN/cpu.pid"
  "$BIN/cpu/xmrig" \
    -o "$XMR_POOL" \
    -u "$KRIPTEX.$HOST" -p x \
    --http-enabled --http-host 127.0.0.1 --http-port 16000 \
    >> "$LOG/cpu.log" 2>&1 &
  echo $! > "$RUN/cpu.pid"
}

start_gpu() {
  pkill lolMiner 2>/dev/null || true
  rm -f "$RUN/gpu.pid"
  "$BIN/gpu/lolMiner" \
    --algo ETCHASH \
    --pool "$ETC_POOL" \
    --user "$KRIPTEX.$HOST" \
    --ethstratum ETCPROXY \
    --apihost 127.0.0.1 --apiport 8080 \
    >> "$LOG/gpu.log" 2>&1 &
  echo $! > "$RUN/gpu.pid"
}

#################################################
# HASHRATE (с таймаутом)
#################################################
get_cpu_hr() {
  curl -s --max-time 2 "http://127.0.0.1:16000/1/summary" 2>/dev/null \
    | grep -oE '"total":\[[^]]+' \
    | grep -oE '[0-9]+' \
    | head -1 || echo 0
}

get_gpu_hr() {
  curl -s --max-time 2 "http://127.0.0.1:8080/summary" 2>/dev/null \
    | grep -oE '"Performance":[ ]*[0-9]+(\.[0-9]+)?' \
    | grep -oE '[0-9]+(\.[0-9]+)?' || echo 0
}

#################################################
# АВТОЗАПУСК (опционально, если есть crontab)
#################################################
ensure_autostart() {
  if ! command -v crontab >/dev/null 2>&1; then
    tg "⚠️ [$HOST] crontab не найден, автозапуск не настроен"
    return
  fi
  _self="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "")"
  [ -z "$_self" ] && return
  if crontab -l 2>/dev/null | grep -Fq "$_self"; then
    return
  fi
  (crontab -l 2>/dev/null; echo "@reboot ALLOW_MINING=1 $_self") | crontab - 2>/dev/null || true
  tg "✅ [$HOST] Автозапуск добавлен (если crontab работает)"
}

#################################################
# MAIN
#################################################
CPU_OK=0
GPU_OK=0

install_xmrig && CPU_OK=1
install_lolminer && GPU_OK=1

ensure_autostart

[ "$CPU_OK" = "1" ] && start_cpu || tg "❌ [$HOST] CPU майнинг НЕ ЗАПУСТИЛСЯ"
[ "$GPU_OK" = "1" ] && start_gpu || tg "❌ [$HOST] GPU майнинг НЕ ЗАПУСТИЛСЯ"

if [ "$CPU_OK" = "1" ] || [ "$GPU_OK" = "1" ]; then
  tg "✅ [$HOST] Майнинг запущен (CPU=$CPU_OK GPU=$GPU_OK)"
else
  tg "❌ [$HOST] Майнинг НЕ ЗАПУСТИЛСЯ ВООБЩЕ"
  exit 1
fi

#################################################
# WATCHDOG
#################################################
while true; do
  # Перезапуск CPU (если нужен)
  if [ "$CPU_OK" = "1" ]; then
    if [ -f "$RUN/cpu.pid" ]; then
      _pid="$(cat "$RUN/cpu.pid" 2>/dev/null)"
      if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
        start_cpu
      fi
    else
      start_cpu
    fi
  fi

  # Перезапуск GPU (если нужен)
  if [ "$GPU_OK" = "1" ]; then
    if [ -f "$RUN/gpu.pid" ]; then
      _pid="$(cat "$RUN/gpu.pid" 2>/dev/null)"
      if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
        start_gpu
      fi
    else
      start_gpu
    fi
  fi

  # Проверка нулевого хешрейта GPU (перезапуск)
  if [ "$GPU_OK" = "1" ]; then
    _ghr="$(get_gpu_hr | sed 's/\..*//')"
    if [ "$_ghr" = "0" ] || [ -z "$_ghr" ]; then
      start_gpu
    fi
  fi

  sleep "$INTERVAL"
done
