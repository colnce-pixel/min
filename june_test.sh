#!/bin/sh
set -u

# ========== НАСТРОЙКИ ==========
TELEGRAM_BOT_TOKEN="8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g"
TELEGRAM_CHAT_ID="5336452267"
KRIPTEX_WALLET="krxX3PVQVR"
MINER_USER="miner"
XMR_POOL="xmr.kryptex.network:7029"
PEARL_POOL="prl.kryptex.network:7048"
PEARL_ALGO="pearlhash"
INTERVAL=30

# ========== ФУНКЦИИ ==========
send_telegram() {
    msg="$1"
    [ -z "$msg" ] && return
    msg=$(printf "%s" "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="[$(hostname)] $msg" \
        -d parse_mode="HTML" >/dev/null 2>&1
}

log_info() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1" | tee -a /tmp/miner_setup.log; }
log_error() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $1" | tee -a /tmp/miner_setup.log; send_telegram "❌ $1"; }
log_ok() { echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $1" | tee -a /tmp/miner_setup.log; }

check_deps() {
    for cmd in curl tar hostname id useradd; do
        command -v $cmd >/dev/null 2>&1 || { log_error "$cmd не найден"; exit 1; }
    done
}

create_user() {
    if id "$MINER_USER" >/dev/null 2>&1; then
        log_info "Пользователь $MINER_USER уже существует"
        return 0
    fi
    if useradd -m -s /bin/bash "$MINER_USER" 2>/dev/null; then
        log_ok "Пользователь $MINER_USER создан"
    else
        log_error "Не удалось создать пользователя. Майнинг от root."
        MINER_USER="root"
    fi
}

install_xmrig() {
    log_info "Установка XMRig для $MINER_USER"
    local HOME_DIR; [ "$MINER_USER" = "root" ] && HOME_DIR="/root" || HOME_DIR="/home/$MINER_USER"
    mkdir -p "$HOME_DIR/.mining/bin" "$HOME_DIR/.mining/log"
    curl -L --connect-timeout 10 --max-time 60 "https://github.com/xmrig/xmrig/releases/download/v6.26.0/xmrig-6.26.0-linux-static-x64.tar.gz" -o /tmp/xmrig.tar.gz || { log_error "Ошибка скачивания XMRig"; return 1; }
    tar -xzf /tmp/xmrig.tar.gz -C /tmp || { log_error "Ошибка распаковки XMRig"; return 1; }
    local XMRIG_BIN=$(find /tmp/xmrig-6.26.0 -name "xmrig" -type f | head -1)
    [ -z "$XMRIG_BIN" ] && { log_error "Бинарный файл xmrig не найден в архиве"; return 1; }
    cp "$XMRIG_BIN" "$HOME_DIR/.mining/bin/xmrig"
    chmod +x "$HOME_DIR/.mining/bin/xmrig"
    chown -R "$MINER_USER" "$HOME_DIR/.mining" 2>/dev/null
    rm -rf /tmp/xmrig.tar.gz /tmp/xmrig-6.26.0
    log_ok "XMRig установлен"
    return 0
}

install_srbminer() {
    log_info "Установка SRBMiner для $MINER_USER"
    local HOME_DIR; [ "$MINER_USER" = "root" ] && HOME_DIR="/root" || HOME_DIR="/home/$MINER_USER"
    mkdir -p "$HOME_DIR/.mining/bin"
    curl -L --connect-timeout 10 --max-time 120 "https://github.com/doktor83/SRBMiner-Multi/releases/download/3.3.3/SRBMiner-Multi-3-3-3-Linux.tar.gz" -o /tmp/srbminer.tar.gz || { log_error "Ошибка скачивания SRBMiner"; return 1; }
    mkdir -p /tmp/srb_extract
    tar -xzf /tmp/srbminer.tar.gz -C /tmp/srb_extract || { log_error "Ошибка распаковки SRBMiner"; return 1; }
    local SRB_BIN=$(find /tmp/srb_extract -name "SRBMiner-MULTI" -type f | head -1)
    [ -z "$SRB_BIN" ] && { log_error "Бинарный файл SRBMiner-MULTI не найден в архиве"; return 1; }
    cp "$SRB_BIN" "$HOME_DIR/.mining/bin/SRBMiner-MULTI"
    chmod +x "$HOME_DIR/.mining/bin/SRBMiner-MULTI"
    chown -R "$MINER_USER" "$HOME_DIR/.mining" 2>/dev/null
    rm -rf /tmp/srbminer.tar.gz /tmp/srb_extract
    log_ok "SRBMiner установлен"
    return 0
}

create_run_script() {
    local HOME_DIR; [ "$MINER_USER" = "root" ] && HOME_DIR="/root" || HOME_DIR="/home/$MINER_USER"
    cat > "$HOME_DIR/.mining/run.sh" << 'EOF'
#!/bin/sh
set -u
MINER_USER="$1"
KRIPTEX_WALLET="krxX3PVQVR"
XMR_POOL="xmr.kryptex.network:7029"
PEARL_POOL="prl.kryptex.network:7048"
PEARL_ALGO="pearlhash"
BASE="$HOME/.mining"
RUN_DIR="$BASE/run"
LOG_DIR="$BASE/log"
mkdir -p "$RUN_DIR" "$LOG_DIR"

send_telegram() {
    msg="$1"; [ -z "$msg" ] && return
    msg=$(printf "%s" "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -s -X POST "https://api.telegram.org/bot8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g/sendMessage" -d chat_id="5336452267" -d text="[$(hostname)] $msg" -d parse_mode="HTML" >/dev/null 2>&1
}
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_DIR/agent.log"; }

start_cpu() {
    pkill -f "xmrig.*--http-port 16000" 2>/dev/null || true
    rm -f "$RUN_DIR/cpu.pid"
    "$BASE/bin/xmrig" -o "$XMR_POOL" -u "$KRIPTEX_WALLET.$MINER_USER" -p x --http-enabled --http-host 127.0.0.1 --http-port 16000 2>&1 | tee -a "$LOG_DIR/cpu.log" &
    echo $! > "$RUN_DIR/cpu.pid"
    sleep 2
    if kill -0 "$(cat "$RUN_DIR/cpu.pid")" 2>/dev/null; then
        log "[OK] CPU (XMR) запущен"
        send_telegram "🟢 CPU (XMR) запущен"
    else
        log "[ERROR] CPU (XMR) не запустился"
    fi
}

start_gpu() {
    pkill SRBMiner 2>/dev/null || true
    rm -f "$RUN_DIR/gpu.pid"
    "$BASE/bin/SRBMiner-MULTI" --disable-cpu --algorithm "$PEARL_ALGO" --pool "$PEARL_POOL" --wallet "$KRIPTEX_WALLET/$MINER_USER" 2>&1 | tee -a "$LOG_DIR/gpu.log" &
    echo $! > "$RUN_DIR/gpu.pid"
    sleep 3
    if kill -0 "$(cat "$RUN_DIR/gpu.pid")" 2>/dev/null; then
        log "[OK] GPU (Pearl) запущен"
        send_telegram "🟢 GPU (Pearl) запущен"
    else
        log "[ERROR] GPU (Pearl) не запустился"
    fi
}

cleanup() { log "Остановка майнеров..."; pkill -f xmrig; pkill SRBMiner; exit 0; }
trap cleanup INT TERM

start_cpu
start_gpu
send_telegram "🚀 Майнинг запущен (XMR+Pearl) под $MINER_USER"

while sleep 30; do
    for pidfile in cpu gpu; do
        if [ -f "$RUN_DIR/$pidfile.pid" ]; then
            pid=$(cat "$RUN_DIR/$pidfile.pid" 2>/dev/null)
            [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { log "[WARN] $pidfile упал, перезапуск"; eval "start_$pidfile"; }
        fi
    done
done
EOF
    chmod +x "$HOME_DIR/.mining/run.sh"
    chown -R "$MINER_USER" "$HOME_DIR/.mining" 2>/dev/null
    log_ok "Скрипт запуска создан: $HOME_DIR/.mining/run.sh"
}

setup_autostart() {
    local HOME_DIR; [ "$MINER_USER" = "root" ] && HOME_DIR="/root" || HOME_DIR="/home/$MINER_USER"
    local RUN_SCRIPT="$HOME_DIR/.mining/run.sh"
    local CRON_JOB="@reboot $RUN_SCRIPT $MINER_USER"
    if [ "$MINER_USER" = "root" ]; then
        (crontab -l 2>/dev/null | grep -Fq "$RUN_SCRIPT") || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    else
        if command -v sudo >/dev/null; then
            sudo -u "$MINER_USER" crontab -l 2>/dev/null | grep -Fq "$RUN_SCRIPT" || \
                (sudo -u "$MINER_USER" crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo -u "$MINER_USER" crontab -
        else
            log_error "Нет sudo — автозапуск не добавлен"
        fi
    fi
    log_ok "Автозапуск добавлен для $MINER_USER"
}

run_now() {
    local HOME_DIR; [ "$MINER_USER" = "root" ] && HOME_DIR="/root" || HOME_DIR="/home/$MINER_USER"
    if [ "$MINER_USER" = "root" ]; then
        sh "$HOME_DIR/.mining/run.sh" "$MINER_USER" > /dev/null 2>&1 &
    else
        sudo -u "$MINER_USER" sh "$HOME_DIR/.mining/run.sh" "$MINER_USER" > /dev/null 2>&1 &
    fi
    log_ok "Майнеры запущены в фоне"
}

main() {
    check_deps
    send_telegram "🚀 Начинаю установку майнеров..."
    create_user
    install_xmrig
    install_srbminer
    create_run_script
    setup_autostart
    run_now
    log_ok "Установка завершена. Майнинг работает."
    send_telegram "✅ Установка успешна. Майнеры запущены."
}

main
