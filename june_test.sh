#!/bin/sh
set -u

# ========== ЖЁСТКО ЗАДАННЫЕ ПАРАМЕТРЫ (замените при необходимости) ==========
TELEGRAM_BOT_TOKEN="8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g"
TELEGRAM_CHAT_ID="5336452267"
KRIPTEX_WALLET="krxX3PVQVR"
HOSTNAME_SHORT="$(hostname | tr -d '\n' | tr -c 'a-zA-Z0-9_-_' '_')"

XMR_POOL="xmr.kryptex.network:7029"
PEARL_POOL="prl-eu.kryptex.network:7048"
PEARL_ALGO="PXL"
INTERVAL=30

BASE="$HOME/.mining"
BIN="$BASE/bin"
RUN="$BASE/run"
LOG="$BASE/log"
mkdir -p "$BIN/cpu" "$BIN/gpu" "$RUN" "$LOG" 2>/dev/null

send_telegram() {
    msg=$(printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="[${HOSTNAME_SHORT}] $msg" \
        -d parse_mode="HTML" >/dev/null 2>&1
}

log_info() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" | tee -a "$LOG/agent.log"; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$LOG/agent.log"; send_telegram "❌ $1"; }
log_ok() { echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" | tee -a "$LOG/agent.log"; }

check_deps() {
    command -v curl >/dev/null || { log_error "curl не найден"; exit 1; }
    command -v tar >/dev/null || { log_error "tar не найден"; exit 1; }
    command -v hostname >/dev/null || { log_error "hostname не найден"; exit 1; }
}

get_ip() {
    ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i!~/^127\./){print $i; exit}}')
    [ -n "$ip" ] && echo "$ip" && return
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}' 2>/dev/null)
    echo "${ip:-0.0.0.0}"
}

AGENT_IP="$(get_ip)"
log_info "Агент запущен на $HOSTNAME_SHORT, IP: $AGENT_IP"
send_telegram "🚀 Агент запущен на <b>$HOSTNAME_SHORT</b> (IP: $AGENT_IP)"

install_xmrig() {
    log_info "Установка XMRig..."
    pkill xmrig 2>/dev/null || true
    rm -f "$BIN/cpu/xmrig"
    for url in \
        "https://xmrig.com/download/xmrig-6.25.0-linux-static-x64.tar.gz" \
        "https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-x64.tar.gz"
    do
        curl -L --connect-timeout 10 --max-time 60 "$url" -o /tmp/xmrig.tgz && break
    done
    [ -f /tmp/xmrig.tgz ] || { log_error "Скачать XMRig не удалось"; return 1; }
    tar -xzf /tmp/xmrig.tgz -C "$BIN/cpu" --strip-components=1
    chmod +x "$BIN/cpu/xmrig"
    rm -f /tmp/xmrig.tgz
    [ -x "$BIN/cpu/xmrig" ] && log_ok "XMRig установлен" || { log_error "Ошибка распаковки XMRig"; return 1; }
    return 0
}

install_lolminer() {
    log_info "Установка lolMiner..."
    pkill lolMiner 2>/dev/null || true
    rm -f "$BIN/gpu/lolMiner"
    curl -L --connect-timeout 10 --max-time 120 "https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz" -o /tmp/lolminer.tgz
    [ -f /tmp/lolminer.tgz ] || { log_error "Скачать lolMiner не удалось"; return 1; }
    tar -xzf /tmp/lolminer.tgz -C "$BIN/gpu" --strip-components=1
    chmod +x "$BIN/gpu/lolMiner"
    rm -f /tmp/lolminer.tgz
    [ -x "$BIN/gpu/lolMiner" ] && log_ok "lolMiner установлен" || { log_error "Ошибка распаковки lolMiner"; return 1; }
    return 0
}

start_cpu() {
    pkill -f "xmrig.*--http-port 16000" 2>/dev/null || true
    rm -f "$RUN/cpu.pid"
    "$BIN/cpu/xmrig" -o "$XMR_POOL" -u "$KRIPTEX_WALLET.$HOSTNAME_SHORT" -p x \
        --http-enabled --http-host 127.0.0.1 --http-port 16000 2>&1 | tee -a "$LOG/cpu.log" &
    echo $! > "$RUN/cpu.pid"
    sleep 2
    kill -0 "$(cat "$RUN/cpu.pid")" 2>/dev/null && log_ok "CPU (XMR) запущен, PID=$(cat "$RUN/cpu.pid")" || { log_error "CPU не запустился"; return 1; }
    send_telegram "🟢 CPU (XMR) запущен"
    return 0
}

start_gpu() {
    pkill lolMiner 2>/dev/null || true
    rm -f "$RUN/gpu.pid"
    "$BIN/gpu/lolMiner" --algo "$PEARL_ALGO" --pool "$PEARL_POOL" \
        --user "$KRIPTEX_WALLET.$HOSTNAME_SHORT" --apihost 127.0.0.1 --apiport 8080 2>&1 | tee -a "$LOG/gpu.log" &
    echo $! > "$RUN/gpu.pid"
    sleep 3
    kill -0 "$(cat "$RUN/gpu.pid")" 2>/dev/null && log_ok "GPU (Pearl) запущен, PID=$(cat "$RUN/gpu.pid")" || { log_error "GPU не запустился"; return 1; }
    send_telegram "🟢 GPU (Pearl) запущен"
    return 0
}

get_cpu_hr() { curl -s --max-time 5 "http://127.0.0.1:16000/1/summary" 2>/dev/null | grep -oE '"total":\[[^]]+' | grep -oE '[0-9]+' | head -1 || echo "0"; }
get_gpu_hr() { curl -s --max-time 5 "http://127.0.0.1:8080/summary" 2>/dev/null | grep -oE '"Performance":[ ]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' || echo "0"; }

setup_autostart() {
    sp="$(realpath "$0")"
    crontab -l 2>/dev/null | grep -Fq "$sp" && return
    (crontab -l 2>/dev/null; echo "@reboot $sp") | crontab - 2>/dev/null && log_ok "Автозапуск добавлен" || log_error "Не удалось добавить автозапуск"
}

cleanup() { log_info "Остановка..."; pkill -f xmrig 2>/dev/null; pkill lolMiner 2>/dev/null; exit 0; }
trap cleanup INT TERM

main() {
    check_deps
    CPU_OK=0; GPU_OK=0
    for try in 1 2 3; do
        [ $CPU_OK -eq 0 ] && install_xmrig && CPU_OK=1
        [ $GPU_OK -eq 0 ] && install_lolminer && GPU_OK=1
        [ $CPU_OK -eq 1 ] && [ $GPU_OK -eq 1 ] && break
        sleep 5
    done
    [ $CPU_OK -eq 0 ] && log_error "XMRig не установлен"
    [ $GPU_OK -eq 0 ] && log_error "lolMiner не установлен"
    [ $CPU_OK -eq 1 ] && start_cpu
    [ $GPU_OK -eq 1 ] && start_gpu
    if [ $CPU_OK -eq 0 ] && [ $GPU_OK -eq 0 ]; then
        log_error "Ни один майнер не запущен"
        send_telegram "❌ Критическая ошибка: майнеры не работают"
        exit 1
    fi
    setup_autostart

    LAST_MIN=0
    while true; do
        if [ $CPU_OK -eq 1 ] && [ -f "$RUN/cpu.pid" ]; then
            pid=$(cat "$RUN/cpu.pid" 2>/dev/null)
            [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && { log_error "CPU упал, перезапуск"; start_cpu; }
        fi
        if [ $GPU_OK -eq 1 ] && [ -f "$RUN/gpu.pid" ]; then
            pid=$(cat "$RUN/gpu.pid" 2>/dev/null)
            [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && { log_error "GPU упал, перезапуск"; start_gpu; }
        fi
        if [ $GPU_OK -eq 1 ]; then
            ghr=$(get_gpu_hr | sed 's/\..*//')
            [ "$ghr" = "0" ] && { log_error "GPU хешрейт 0, перезапуск"; start_gpu; }
        fi
        now=$(date +%M)
        if [ "$now" != "$LAST_MIN" ]; then
            LAST_MIN="$now"
            cpu_hr=$(get_cpu_hr)
            gpu_hr=$(get_gpu_hr)
            send_telegram "📊 Хешрейт: XMR = ${cpu_hr} H/s, Pearl = ${gpu_hr} MH/s"
        fi
        sleep "$INTERVAL"
    done
}

main
