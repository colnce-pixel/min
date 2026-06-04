cat > /tmp/miner_fixed.sh << 'EOF'
#!/bin/sh
set -u

# ========== ЖЁСТКО ЗАДАННЫЕ ПАРАМЕТРЫ ==========
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

# ========== ОТПРАВКА В TELEGRAM ==========
send_telegram() {
    msg="$1"
    msg=$(printf "%s" "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="[${HOSTNAME_SHORT}] $msg" \
        -d parse_mode="HTML" >/dev/null 2>&1
}

# ========== ЛОГИРОВАНИЕ В КОНСОЛЬ + ФАЙЛ ==========
log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" | tee -a "$LOG/agent.log"
}
log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a "$LOG/agent.log"
    send_telegram "❌ Ошибка: $1"
}
log_ok() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" | tee -a "$LOG/agent.log"
}

# ========== ПРОВЕРКА ЗАВИСИМОСТЕЙ (без nproc/ip – fallback) ==========
check_deps() {
    command -v curl >/dev/null 2>&1 || { log_error "curl не найден"; exit 1; }
    command -v tar >/dev/null 2>&1 || { log_error "tar не найден"; exit 1; }
    command -v hostname >/dev/null 2>&1 || { log_error "hostname не найден"; exit 1; }
    # nproc и ip не обязательны, используем fallback
    if ! command -v nproc >/dev/null 2>&1; then
        log_info "nproc не найден, используем 2 потока CPU"
        NPROC_FALLBACK=2
    else
        NPROC_FALLBACK=$(nproc)
    fi
    if ! command -v ip >/dev/null 2>&1; then
        log_info "ip не найден, IP не будет определён"
    fi
}

# ========== ПОЛУЧЕНИЕ IP (опционально) ==========
get_ip() {
    ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}')
    [ -n "$ip" ] && echo "$ip" && return
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}' 2>/dev/null)
    [ -n "$ip" ] && echo "$ip" && return
    echo "0.0.0.0"
}

AGENT_IP="$(get_ip)"
log_info "Агент запущен на $HOSTNAME_SHORT, IP: $AGENT_IP"
send_telegram "🚀 Агент запущен на <b>$HOSTNAME_SHORT</b> (IP: $AGENT_IP)"

# ========== УСТАНОВКА XMRig ==========
install_xmrig() {
    log_info "Установка XMRig..."
    pkill xmrig 2>/dev/null || true
    rm -f "$BIN/cpu/xmrig" 2>/dev/null

    for url in \
        "https://xmrig.com/download/xmrig-6.25.0-linux-static-x64.tar.gz" \
        "https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-x64.tar.gz"
    do
        curl -L --connect-timeout 10 --max-time 60 "$url" -o /tmp/xmrig.tgz 2>&1 | tee -a "$LOG/agent.log"
        [ -f /tmp/xmrig.tgz ] && break
    done
    if [ ! -f /tmp/xmrig.tgz ]; then
        log_error "Не удалось скачать XMRig"
        return 1
    fi
    tar -xzf /tmp/xmrig.tgz -C "$BIN/cpu" --strip-components=1 2>&1 | tee -a "$LOG/agent.log"
    chmod +x "$BIN/cpu/xmrig"
    if [ -x "$BIN/cpu/xmrig" ]; then
        log_ok "XMRig установлен"
        rm -f /tmp/xmrig.tgz
        return 0
    else
        log_error "Не удалось распаковать XMRig"
        return 1
    fi
}

# ========== УСТАНОВКА lolMiner ==========
install_lolminer() {
    log_info "Установка lolMiner..."
    pkill lolMiner 2>/dev/null || true
    rm -f "$BIN/gpu/lolMiner" 2>/dev/null

    url="https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz"
    curl -L --connect-timeout 10 --max-time 120 "$url" -o /tmp/lolminer.tgz 2>&1 | tee -a "$LOG/agent.log"
    if [ ! -f /tmp/lolminer.tgz ]; then
        log_error "Не удалось скачать lolMiner"
        return 1
    fi
    tar -xzf /tmp/lolminer.tgz -C "$BIN/gpu" --strip-components=1 2>&1 | tee -a "$LOG/agent.log"
    chmod +x "$BIN/gpu/lolMiner"
    if [ -x "$BIN/gpu/lolMiner" ]; then
        log_ok "lolMiner установлен"
        rm -f /tmp/lolminer.tgz
        return 0
    else
        log_error "Не удалось распаковать lolMiner"
        return 1
    fi
}

# ========== ЗАПУСК МАЙНЕРОВ (вывод в консоль и в лог) ==========
start_cpu() {
    pkill -f "xmrig.*--http-port 16000" 2>/dev/null || true
    rm -f "$RUN/cpu.pid"
    "$BIN/cpu/xmrig" \
        -o "$XMR_POOL" \
        -u "$KRIPTEX_WALLET.$HOSTNAME_SHORT" -p x \
        --http-enabled --http-host 127.0.0.1 --http-port 16000 \
        2>&1 | tee -a "$LOG/cpu.log" &
    echo $! > "$RUN/cpu.pid"
    sleep 2
    if kill -0 "$(cat "$RUN/cpu.pid")" 2>/dev/null; then
        log_ok "CPU майнер (XMR) запущен, PID=$(cat "$RUN/cpu.pid")"
        send_telegram "🟢 CPU (XMR) запущен"
        return 0
    else
        log_error "CPU майнер не запустился"
        return 1
    fi
}

start_gpu() {
    pkill lolMiner 2>/dev/null || true
    rm -f "$RUN/gpu.pid"
    "$BIN/gpu/lolMiner" \
        --algo "$PEARL_ALGO" \
        --pool "$PEARL_POOL" \
        --user "$KRIPTEX_WALLET.$HOSTNAME_SHORT" \
        --apihost 127.0.0.1 --apiport 8080 \
        2>&1 | tee -a "$LOG/gpu.log" &
    echo $! > "$RUN/gpu.pid"
    sleep 3
    if kill -0 "$(cat "$RUN/gpu.pid")" 2>/dev/null; then
        log_ok "GPU майнер (Pearl) запущен, PID=$(cat "$RUN/gpu.pid")"
        send_telegram "🟢 GPU (Pearl) запущен"
        return 0
    else
        log_error "GPU майнер не запустился"
        return 1
    fi
}

# ========== ХЕШРЕЙТ ==========
get_cpu_hr() {
    curl -s --max-time 5 "http://127.0.0.1:16000/1/summary" 2>/dev/null | \
        grep -oE '"total":\[[^]]+' | grep -oE '[0-9]+' | head -1 || echo "0"
}
get_gpu_hr() {
    curl -s --max-time 5 "http://127.0.0.1:8080/summary" 2>/dev/null | \
        grep -oE '"Performance":[ ]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' || echo "0"
}

# ========== АВТОЗАПУСК ==========
setup_autostart() {
    script_path="$(realpath "$0")"
    if ! crontab -l 2>/dev/null | grep -Fq "$script_path"; then
        (crontab -l 2>/dev/null; echo "@reboot $script_path") | crontab - 2>/dev/null
        if [ $? -eq 0 ]; then
            log_ok "Автозапуск добавлен в crontab"
        else
            log_error "Не удалось добавить автозапуск"
        fi
    fi
}

# ========== ОСТАНОВКА ПРИ Ctrl+C ==========
cleanup() {
    log_info "Получен сигнал остановки, убиваем майнеры..."
    pkill -f xmrig 2>/dev/null
    pkill lolMiner 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# ========== ГЛАВНАЯ ФУНКЦИЯ ==========
main() {
    check_deps

    CPU_OK=0
    GPU_OK=0
    for try in 1 2 3; do
        [ $CPU_OK -eq 0 ] && install_xmrig && CPU_OK=1
        [ $GPU_OK -eq 0 ] && install_lolminer && GPU_OK=1
        [ $CPU_OK -eq 1 ] && [ $GPU_OK -eq 1 ] && break
        sleep 5
    done

    [ $CPU_OK -eq 0 ] && log_error "XMRig не установлен после 3 попыток"
    [ $GPU_OK -eq 0 ] && log_error "lolMiner не установлен после 3 попыток"

    [ $CPU_OK -eq 1 ] && start_cpu
    [ $GPU_OK -eq 1 ] && start_gpu

    if [ $CPU_OK -eq 0 ] && [ $GPU_OK -eq 0 ]; then
        log_error "Ни один майнер не запущен. Выход."
        send_telegram "❌ Критическая ошибка: майнеры не работают"
        exit 1
    fi

    setup_autostart

    LAST_TELEGRAM_MINUTE=0
    while true; do
        # Проверка CPU
        if [ $CPU_OK -eq 1 ] && [ -f "$RUN/cpu.pid" ]; then
            pid=$(cat "$RUN/cpu.pid" 2>/dev/null)
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                log_error "CPU майнер упал, перезапуск"
                start_cpu
            fi
        fi

        # Проверка GPU
        if [ $GPU_OK -eq 1 ] && [ -f "$RUN/gpu.pid" ]; then
            pid=$(cat "$RUN/gpu.pid" 2>/dev/null)
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                log_error "GPU майнер упал, перезапуск"
                start_gpu
            fi
        fi

        # Проверка хешрейта GPU
        if [ $GPU_OK -eq 1 ]; then
            gpu_hr=$(get_gpu_hr | sed 's/\..*//')
            if [ "$gpu_hr" = "0" ] || [ -z "$gpu_hr" ]; then
                log_error "GPU хешрейт = 0, перезапуск"
                start_gpu
            fi
        fi

        current_minute=$(date +%M)
        if [ "$current_minute" != "$LAST_TELEGRAM_MINUTE" ]; then
            LAST_TELEGRAM_MINUTE="$current_minute"
            cpu_hr=$(get_cpu_hr)
            gpu_hr=$(get_gpu_hr)
            send_telegram "📊 Хешрейт: XMR = ${cpu_hr} H/s, Pearl = ${gpu_hr} MH/s"
        fi

        sleep "$INTERVAL"
    done
}

main
EOF
chmod +x /tmp/miner_fixed.sh && /tmp/miner_fixed.sh
