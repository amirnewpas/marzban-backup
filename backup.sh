#!/bin/bash

BACKUP_SCRIPT_PATH="/root/backup_marzban.sh"

cat <<'EOF' > "$BACKUP_SCRIPT_PATH"
#!/bin/bash

ENV_FILE="/opt/marzban/.env"
PASS_FILE="/root/.marzban_mysql_password"
BASE_DIR="/root/backup_marzban"
DB_DIR="$BASE_DIR/db"
OPT_DIR="$BASE_DIR/opt"
VARLIB_DIR="$BASE_DIR/varlib"
CONTAINER_NAME="marzban-mysql-1"
VARLIB_SOURCE="/var/lib/marzban"

function get_persian_date() {
    if command -v python3 &> /dev/null; then
        python3 -c "from persiantools.jdatetime import JalaliDateTime; print(JalaliDateTime.now().strftime('%-d/%-m/%Y %H:%M:%S'))" 2>/dev/null || echo "Persian date unavailable"
    else
        echo "Persian date unavailable"
    fi
}

function extract_password() {
    if [[ -f "$ENV_FILE" ]]; then
        grep "^MYSQL_ROOT_PASSWORD=" "$ENV_FILE" | head -n1 | cut -d "=" -f2- > "$PASS_FILE"
        [[ $? -eq 0 ]] || { echo "Failed to extract password"; exit 1; }
    else
        echo "$ENV_FILE not found!"; exit 1
    fi
}

function show_progress() {
    local percent=$1
    local message="$2"
    local bar=""
    local total=20
    local filled=$((percent * total / 100))
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=filled; i<total; i++)); do bar+="."; done
    printf "\r[%-20s] %3d%% - %s" "$bar" "$percent" "$message"
}

function backup_and_send() {
    MYSQL_ROOT_PASSWORD=$(cat "$PASS_FILE" | tr -d "\r\n ")
    [[ -n "$MYSQL_ROOT_PASSWORD" ]] || { echo "Password file is empty."; exit 1; }
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || { echo "Bot token or Chat ID not set"; exit 1; }

    mkdir -p "$DB_DIR" "$OPT_DIR" "$VARLIB_DIR"

    show_progress 10 "Password extracted"; sleep 1
    show_progress 25 "Starting backup..."; sleep 1

    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzban > "$DB_DIR/marzban.sql"
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzhelp > "$DB_DIR/marzhelp.sql"
    show_progress 35 "Dumping databases..."; sleep 1

    tar -czf "$DB_DIR/db_backup.tar.gz" -C "$DB_DIR" marzban.sql marzhelp.sql
    rm -f "$DB_DIR/marzban.sql" "$DB_DIR/marzhelp.sql"
    show_progress 50 "Compressing DB dump..."; sleep 1

    if [[ -f "/opt/marzban/.env" && -f "/opt/marzban/docker-compose.yml" ]]; then
        tar -czf "$OPT_DIR/marzban_opt_backup.tar.gz" -C /opt/marzban .env docker-compose.yml
    fi
    show_progress 60 "Backing up /opt/marzban..."; sleep 1

    if [[ -d "$VARLIB_SOURCE" ]]; then
        rsync -a --exclude="mysql" --exclude="xray-core" "$VARLIB_SOURCE/" "$VARLIB_DIR/"
        tar -czf "$VARLIB_DIR/varlib_backup.tar.gz" -C "$VARLIB_DIR" .
        find "$VARLIB_DIR" ! -name "varlib_backup.tar.gz" -type f -delete
        find "$VARLIB_DIR" ! -name "varlib_backup.tar.gz" -type d -empty -delete
    fi
    show_progress 75 "Backing up /var/lib/marzban..."; sleep 1

    cd "$BASE_DIR" || exit 1
    FINAL_ARCHIVE="marzban_full_backup_$(date +'%Y%m%d_%H%M%S').tar.gz"
    rm -f marzban_full_backup_*.tar.gz
    tar -czf "$FINAL_ARCHIVE" db opt varlib
    show_progress 85 "Creating final archive..."; sleep 1

    echo "$(date +'%Y-%m-%d %H:%M:%S')" > /root/.last_backup_time

    # Prepare Persian and Gregorian date only for caption
    PERSIAN_DATE=$(get_persian_date)
    GREGORIAN_DATE=$(date +"%Y-%m-%d %H:%M:%S")

    CAPTION="فایل پشتیبان‌گیری ساخته شد
📅 تاریخ میلادی: $GREGORIAN_DATE
📅 تاریخ شمسی: $PERSIAN_DATE

🔗 گیت‌هاب: https://github.com/amirnewpas/marzban-backup
🔗 تلگرام: https://t.me/Programing_psy
"

    response=$(curl -s -F chat_id="$TELEGRAM_CHAT_ID" \
      -F document=@"$BASE_DIR/$FINAL_ARCHIVE" \
      -F caption="$CAPTION" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument")

    if echo "$response" | grep -q "\"ok\":true"; then
        show_progress 100 "✅ Backup sent successfully"
        echo ""
        rm -f "$BASE_DIR/$FINAL_ARCHIVE"
    else
        echo -e "\n❌ Failed to send to Telegram."
        echo "Response: $response"
    fi
}

function change_cron_only() {
    echo "Enter backup interval in hours (1-24):"; read -r INTERVAL
    [[ "$INTERVAL" =~ ^([1-9]|1[0-9]|2[0-4])$ ]] || { echo "Invalid interval."; return 1; }

    CRON_EXPR="0 */$INTERVAL * * *"
    CRON_CMD="/bin/bash $BACKUP_SCRIPT_PATH --run >> /root/backup_marzban.log 2>&1"

    (crontab -l 2>/dev/null | grep -v -F "$BACKUP_SCRIPT_PATH"; echo "$CRON_EXPR $CRON_CMD") | crontab -

    echo "✅ You set cron job for every $INTERVAL hour(s)"
}

function setup_cron() {
    echo "Enter the Telegram Bot Token:"; read -r TELEGRAM_BOT_TOKEN
    echo "Enter the Telegram Chat ID:"; read -r TELEGRAM_CHAT_ID

    echo "$TELEGRAM_BOT_TOKEN" > /root/.telegram_bot_token
    echo "$TELEGRAM_CHAT_ID" > /root/.telegram_chat_id

    change_cron_only
}

function run_backup() {
    [[ -f /root/.telegram_bot_token ]] && TELEGRAM_BOT_TOKEN=$(cat /root/.telegram_bot_token) || { echo "❌ Bot token not found."; return 1; }
    [[ -f /root/.telegram_chat_id ]] && TELEGRAM_CHAT_ID=$(cat /root/.telegram_chat_id) || { echo "❌ Chat ID not found."; return 1; }

    extract_password
    backup_and_send
}

function settings_menu() {
    clear
    echo "=== Settings ==="
    echo "Bot Token: $(cat /root/.telegram_bot_token 2>/dev/null || echo 'Not set')"
    echo "Chat ID: $(cat /root/.telegram_chat_id 2>/dev/null || echo 'Not set')"
    echo "Cron job:"
    crontab -l 2>/dev/null | grep "$BACKUP_SCRIPT_PATH" | while read -r line; do
        echo "-> $line"
    done || echo "No cron job found"
    echo "------------------"
    echo "1) Change Bot Token"
    echo "2) Change Chat ID"
    echo "3) Change Cron Job Interval"
    echo "4) Back"
    read -rp "Choose: " input
    case $input in
        1) echo "Enter new bot token:"; read -r token; echo "$token" > /root/.telegram_bot_token ;;
        2) echo "Enter new chat ID:"; read -r id; echo "$id" > /root/.telegram_chat_id ;;
        3) change_cron_only ;;
        *) ;;
    esac
    read -rp "Press enter to continue..."
}

function show_menu() {
    clear
    echo "=============================="
    echo " Marzban Backup Management Menu"
    echo "=============================="
    LAST_BACKUP="No backup yet"
    if [[ -f /root/.last_backup_time ]]; then
        LAST_BACKUP=$(cat /root/.last_backup_time)
    fi
    echo "Last backup: $LAST_BACKUP"
    echo "=============================="
    echo "1) Install/setup Telegram bot and cron job"
    echo "2) Run backup now and send to Telegram"
    echo "3) Settings"
    echo "4) Exit"
    echo "=============================="
    read -rp "Choose an option: " option
    case $option in
        1) setup_cron ;;
        2) run_backup ;;
        3) settings_menu ;;
        4) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    read -rp "Press enter to continue..."
}

[[ "$1" == "--run" ]] && run_backup || while true; do show_menu; done
EOF

chmod +x "$BACKUP_SCRIPT_PATH"

bash "$BACKUP_SCRIPT_PATH"
