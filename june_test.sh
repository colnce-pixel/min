#!/bin/sh
set -u

###########################################################
# Автономный майнинг-агент: CPU (XMR) + GPU (Pearl)
# Отправка только в Telegram, без внешнего API
# Все настройки захардкожены
###########################################################

# ========== ЖЁСТКО ЗАДАННЫЕ ПАРАМЕТРЫ (замените на свои) ==========
TELEGRAM_BOT_TOKEN="ВАШ_ТОКЕН_БОТА"        # например, "123456:ABC-DEF"
TELEGRAM_CHAT_ID="ВАШ_CHAT_ID"            # например, "123456789"
KRIPTEX_WALLET="krxX3PVQVR"               # ваш кошелёк Kryptex
HOSTNAME_SHORT="$(hostname | tr -d '\n' | tr -c 'a-zA-Z0-9_-_' '_')"

# Пулы
XMR_POOL="xmr.kryptex.network:7029"
PEARL_POOL="prl-eu.kryptex.network:7048"   # можно заменить на prl-ru, prl-us и т.д.
PEARL_ALGO="PXL"

# Интервал проверки watchdog (сек)
INTERVAL=30

# Директории (всё в ~/.mining)
BASE="$HOME/.mining"
BIN="$BASE/bin"
RUN="$BASE/run"
LOG="$BASE/log"

# ========== ФУНКЦИЯ ОТПРАВКИ В TELEGRAM ==========
send_telegram() {
    msg="$1"
    # Экранируем специальные символы JSON
    msg=$(printf "%s" "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="[${HOSTNAME_SHORT}] $msg" \
        -d parse_mode="HTML" >/dev/null 2>&1
}

# ========== ЛОГИРОВАНИЕ (в файл + иногда в Telegram) ==========
log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" >> "$LOG/agent.log"
}
log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" >> "$LOG/agent.log"
    send_telegram "❌ Ошибка: $1"
}
log_ok() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" >> "$LOG/agent.log"
}

# ========== ПРОВЕРКА ЗАВИСИМОСТЕЙ ==========
check_deps() {
    deps="curl tar hostname ip nproc"
    missing=""
    for d in $deps; do
        if ! command -v "$d" >/dev/null 2>&1; then
            missing="$missing $d"
        fi
    done
    if [ -n "$missing" ]; then
        log_error "Отсутствуют команды:$missing"
        send_telegram "⚠️ Установите: apt install curl tar net-tools coreutils (или аналоги)"
        exit 1
    fi
}

# ========== СОЗДАНИЕ ДИРЕКТОРИЙ ==========
mkdir -p "$BIN/cpu" "$BIN/gpu" "$RUN" "$LOG" 2>/dev/null || {
    echo "Не удалось создать директории в $BASE"
    exit 1
}

# ========== ПОЛУЧЕНИЕ IP-АДРЕСА (только для логов) ==========
get_ip() {
    ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i !~ /^127\./){print $i; exit}}')
    [ -n "$ip" ] && echo "$ip" && return
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}')
    [ -n "$ip" ] && echo "$ip" && return
    echo "0.0.0.0"
}
AGENT_IP="$(get_ip)"
log_info "Агент запущен на $HOSTNAME_SHORT, IP: $AGENT_IP"
send_telegram "🚀 Агент запущен на <b>$HOSTNAME_SHORT</b> (IP: $AGENT_IP)"

# ========== УСТАНОВКА XMRig (CPU) ==========
install_xmrig() {
    log_info "Установка XMRig..."
    pkill xmrig 2>/dev/null || true
    rm -f "$BIN/cpu/xmrig" 2>/dev/null

    urls="
        https://xmrig.com/download/xmrig-6.25.0-linux-static-x64.tar.gz
        https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-x64.tar.gz
    "
    for url in $urls; do
        curl -# -L --connect-timeout 10 --max-time 60 "$url" -o /tmp/xmrig.tgz 2>/dev/null && break
    done
    if [ ! -f /tmp/xmrig.tgz ]; then
        log_error "Не удалось скачать XMRig"
        return 1
    fi
    tar -xzf /tmp/xmrig.tgz -C "$BIN/cpu" --strip-components=1 2>/dev/null
    chmod +x "$BIN/cpu/xmrig" 2>/dev/null
    if [ -x "$BIN/cpu/xmrig" ]; then
        log_ok "XMRig установлен"
        rm -f /tmp/xmrig.tgz
        return 0
    else
        log_error "Не удалось распаковать XMRig"
        return 1
    fi
}

# ========== УСТАНОВКА lolMiner (GPU) ==========
install_lolminer() {
    log_info "Установка lolMiner..."
    pkill lolMiner 2>/dev/null || true
    rm -f "$BIN/gpu/lolMiner" 2>/dev/null

    url="https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz"
    curl -# -L --connect-timeout 10 --max-time 120 "$url" -o /tmp/lolminer.tgz 2>/dev/null
    if [ ! -f /tmp/lolminer.tgz ]; then
        log_error "Не удалось скачать lolMiner"
        return 1
    fi
    tar -xzf /tmp/lolminer.tgz -C "$BIN/gpu" --strip-components=1 2>/dev/null
    chmod +x "$BIN/gpu/lolMiner" 2>/dev/null
    if [ -x "$BIN/gpu/lolMiner" ]; then
        log_ok "lolMiner установлен"
        rm -f /tmp/lolminer.tgz
        return 0
    else
        log_error "Не удалось распаковать lolMiner"
        return 1
    fi
}

# ========== ЗАПУСК МАЙНЕРОВ ==========
start_cpu() {
    pkill -f "xmrig.*--http-port 16000" 2>/dev/null || true
    "$BIN/cpu/xmrig" \
        -o "$XMR_POOL" \
        -u "$KRIPTEX_WALLET.$HOSTNAME_SHORT" -p x \
        --http-enabled --http-host 127.0.0.1 --http-port 16000 \
        >> "$LOG/cpu.log" 2>&1 &
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
    "$BIN/gpu/lolMiner" \
        --algo "$PEARL_ALGO" \
        --pool "$PEARL_POOL" \
        --user "$KRIPTEX_WALLET.$HOSTNAME_SHORT" \
        --apihost 127.0.0.1 --apiport 8080 \
        >> "$LOG/gpu.log" 2>&1 &
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

# ========== ПОЛУЧЕНИЕ ХЕШРЕЙТА ==========
get_cpu_hr() {
    curl -s --max-time 5 "http://127.0.0.1:16000/1/summary" 2>/dev/null | \
        grep -oE '"total":\[[^]]+' | grep -oE '[0-9]+' | head -1 || echo "0"
}
get_gpu_hr() {
    curl -s --max-time 5 "http://127.0.0.1:8080/summary" 2>/dev/null | \
        grep -oE '"Performance":[ ]*[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+(\.[0-9]+)?' || echo "0"
}

# ========== НАСТРОЙКА АВТОЗАПУСКА (CRON) ==========
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

# ========== ГЛАВНАЯ ФУНКЦИЯ С ПОВТОРНЫМИ ПОПЫТКАМИ ==========
main() {
    check_deps

    # Установка майнеров с повторными попытками (до 3 раз)
    CPU_OK=0
    GPU_OK=0
    for try in 1 2 3; do
        [ $CPU_OK -eq 0 ] && install_xmrig && CPU_OK=1
        [ $GPU_OK -eq 0 ] && install_lolminer && GPU_OK=1
        [ $CPU_OK -eq 1 ] && [ $GPU_OK -eq 1 ] && break
        sleep 5
    done

    if [ $CPU_OK -eq 0 ]; then
        log_error "XMRig не установлен после 3 попыток"
    fi
    if [ $GPU_OK -eq 0 ]; then
        log_error "lolMiner не установлен после 3 попыток"
    fi

    # Запуск майнеров (если установлены)
    [ $CPU_OK -eq 1 ] && start_cpu
    [ $GPU_OK -eq 1 ] && start_gpu

    if [ $CPU_OK -eq 0 ] && [ $GPU_OK -eq 0 ]; then
        log_error "Ни один майнер не запущен. Выход."
        send_telegram "❌ Критическая ошибка: майнеры не работают"
        exit 1
    fi

    setup_autostart

    # ========== WATCHDOG (вечный цикл) ==========
    LAST_TELEGRAM_MINUTE=0
    while true; do
        # Проверка CPU
        if [ $CPU_OK -eq 1 ] && [ -f "$RUN/cpu.pid" ]; then
            pid=$(cat "$RUN/cpu.pid" 2>/dev/null)
            if ! kill -0 "$pid" 2>/dev/null; then
                log_error "CPU майнер упал, перезапуск"
                start_cpu
            fi
        fi

        # Проверка GPU
        if [ $GPU_OK -eq 1 ] && [ -f "$RUN/gpu.pid" ]; then
            pid=$(cat "$RUN/gpu.pid" 2>/dev/null)
            if ! kill -0 "$pid" 2>/dev/null; then
                log_error "GPU майнер упал, перезапуск"
                start_gpu
            fi
        fi

        # Проверка хешрейта GPU (нулевой -> перезапуск)
        if [ $GPU_OK -eq 1 ]; then
            gpu_hr=$(get_gpu_hr | sed 's/\..*//')  # целая часть
            if [ "$gpu_hr" = "0" ] || [ -z "$gpu_hr" ]; then
                log_error "GPU хешрейт = 0, перезапуск"
                start_gpu
            fi
        fi

        # Отправка сводки в Telegram раз в минуту
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

# Запуск с перенаправлением всего вывода в лог (на случай, если скрипт вызван без консоли)
main 2>&1 | tee -a "$LOG/agent.log"
