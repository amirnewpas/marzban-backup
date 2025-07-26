#!/bin/bash

BACKUP_SCRIPT_PATH="/root/backup.sh"

# اگر اسکریپت به صورت مستقیم اجرا نشود (مثلا توسط curl | bash) آن را ذخیره و اجرا کن
if [[ "$(basename "$0")" != "backup.sh" ]]; then
    echo "Saving script to $BACKUP_SCRIPT_PATH ..."
    curl -Ls https://github.com/amirnewpas/marzban-backup/raw/main/backup.sh -o "$BACKUP_SCRIPT_PATH"
    chmod +x "$BACKUP_SCRIPT_PATH"
    echo "Script saved. Running the script now..."
    exec "$BACKUP_SCRIPT_PATH"
fi

# نمایش نوار پیشرفت درصدی
function show_progress() {
    current=$1
    total=$2
    width=40
    percent=$(( current * 100 / total ))
    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))

    progress_bar="["
    for ((i=0; i<filled; i++)); do progress_bar+="#"; done
    for ((i=0; i<empty; i++)); do progress_bar+="."; done
    progress_bar+="] $percent%"

    echo -ne "\r$progress_bar"
}

# حذف بات و کرون جاب‌های مرتبط با این اسکریپت
function remove_bot() {
    echo "Removing Telegram bot configuration and related cron jobs..."
    rm -f /root/.telegram_bot_token /root/.telegram_chat_id
    # فقط کرون‌هایی که شامل نام اسکریپت هستند را حذف کن
    crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT_PATH" | crontab -
    echo "Removing backup script file..."
    rm -f "$BACKUP_SCRIPT_PATH"
    echo "Bot removed successfully."
    exit 0
}

# تنظیم کرون‌جاب دقیق در ساعت رند با فاصله مشخص
function change_cron_only() {
    echo "Enter backup interval in hours (1-24):"
    read -r INTERVAL
    if [[ ! "$INTERVAL" =~ ^([1-9]|1[0-9]|2[0-4])$ ]]; then
        echo "Invalid interval. Please enter a number between 1 and 24."
        return 1
    fi

    CRON_EXPR="0 */$INTERVAL * * *"
    CRON_CMD="/bin/bash $BACKUP_SCRIPT_PATH --run >> /root/backup.log 2>&1"

    # حذف کرون قبلی حاوی اسکریپت و افزودن کرون جدید
    (crontab -l 2>/dev/null | grep -v -F "$BACKUP_SCRIPT_PATH"; echo "$CRON_EXPR $CRON_CMD") | crontab -

    echo "✅ Cron job set to run every $INTERVAL hour(s) at minute 0."
}

# تنظیم اولیه کرون و توکن بات تلگرام
function setup_cron() {
    echo "Enter the Telegram Bot Token:"
    read -r TELEGRAM_BOT_TOKEN
    echo "Enter the Telegram Chat ID:"
    read -r TELEGRAM_CHAT_ID

    echo "$TELEGRAM_BOT_TOKEN" > /root/.telegram_bot_token
    echo "$TELEGRAM_CHAT_ID" > /root/.telegram_chat_id

    change_cron_only
}

# استخراج پسورد از فایل env
function extract_password() {
    ENV_FILE="/opt/marzban/.env"
    PASS_FILE="/root/.marzban_mysql_password"
    if [[ -f "$ENV_FILE" ]]; then
        grep "^MYSQL_ROOT_PASSWORD=" "$ENV_FILE" | head -n1 | cut -d "=" -f2- > "$PASS_FILE"
        [[ $? -eq 0 ]] || { echo "Failed to extract password"; exit 1; }
    else
        echo "$ENV_FILE not found!"; exit 1
    fi
}

# اجرای بکاپ و ارسال به تلگرام
function backup_and_send() {
    BASE_DIR="/root/backup"
    DB_DIR="$BASE_DIR/db"
    OPT_DIR="$BASE_DIR/opt"
    VAR_DIR="$BASE_DIR/varlib"
    CONTAINER_NAME="marzban-mysql-1"

    MYSQL_ROOT_PASSWORD=$(cat /root/.marzban_mysql_password | tr -d "\r\n ")
    [[ -n "$MYSQL_ROOT_PASSWORD" ]] || { echo "Password file is empty."; exit 1; }
    [[ -f /root/.telegram_bot_token && -f /root/.telegram_chat_id ]] || { echo "Bot token or Chat ID not set"; exit 1; }

    TELEGRAM_BOT_TOKEN=$(cat /root/.telegram_bot_token)
    TELEGRAM_CHAT_ID=$(cat /root/.telegram_chat_id)

    mkdir -p "$DB_DIR" "$OPT_DIR" "$VAR_DIR"

    TOTAL_STEPS=7
    CURRENT_STEP=0

    echo "Starting backup..."
    sleep 1
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress $CURRENT_STEP $TOTAL_STEPS

    echo "Backing up marzban database..."
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzban > "$DB_DIR/marzban.sql"
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress $CURRENT_STEP $TOTAL_STEPS

    echo "Backing up marzhelp database..."
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzhelp > "$DB_DIR/marzhelp.sql"
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress $CURRENT_STEP $TOTAL_STEPS

    tar -czf "$DB_DIR/db_backup.tar.gz" -C "$DB_DIR" marzban.sql marzhelp.sql
    rm -f "$DB_DIR/marzban.sql" "$DB_DIR/marzhelp.sql"
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress $CURRENT_STEP $TOTAL_STEPS

    if [[ -f "/opt/marzban/.env" && -f "/opt/marzban/docker-compose.yml" ]]; then
        tar -czf "$OPT_DIR/marzban_opt_backup.tar.gz" -C /opt/marzban .env docker-compose.yml
    fi
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress $CURRENT_STEP $TOTAL_STEPS

    VARLIB_SOURCE="/var/lib/marzban"
    if [[ -d "$VARLIB_SOURCE" ]]; then
        rsync -a --exclude="mysql" --exclude="xray-core" "$VARLIB_SOURCE/" "$VAR_DIR/"
        tar -czf "$VAR_DIR/varlib_backup.tar.gz" -C "$VAR_DIR" .
        find "$VAR_DIR" ! -name "varlib_backup.tar.gz" -type f -delete
        find "$VAR_DIR" ! -name "varlib_backup.tar.gz" -type d -empty -delete
    fi
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress $CURRENT_STEP $TOTAL_STEPS

    cd "$BASE_DIR" || exit 1
    FINAL_ARCHIVE="marzban_full_backup_$(date +'%Y%m%d_%H%M%S').tar.gz"
    rm -f marzban_full_backup_*.tar.gz
    tar -czf "$FINAL_ARCHIVE" db opt varlib
    CURRENT_STEP=$((CURRENT_STEP+1)); show_progress $CURRENT_STEP $TOTAL_STEPS

    echo "$(date +'%Y-%m-%d %H:%M:%S')" > /root/.last_backup_time

    echo -e "\nSending backup to Telegram..."

    CAPTION="Backup file created successfully
📅 date: $(date +'%Y-%m-%d %H:%M:%S')

🔗 GitHub: https://github.com/amirnewpas/marzban-backup
🔗 Telegram: @Programing_psy
"

    response=$(curl -s -F chat_id="$TELEGRAM_CHAT_ID" \
      -F document=@"$BASE_DIR/$FINAL_ARCHIVE" \
      -F caption="$CAPTION" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument")

    if echo "$response" | grep -q "\"ok\":true"; then
        echo "Backup sent successfully."
        rm -f "$BASE_DIR/$FINAL_ARCHIVE"
    else
        echo "Failed to send backup to Telegram."
        echo "Response: $response"
    fi
}

function run_backup() {
    extract_password
    backup_and_send
}

# منوی تنظیمات
function settings_menu() {
    clear
    echo "=== Settings ==="
    echo "Bot Token: $(cat /root/.telegram_bot_token 2>/dev/null || echo 'Not set')"
    echo "Chat ID: $(cat /root/.telegram_chat_id 2>/dev/null || echo 'Not set')"
    echo "Cron jobs:"
    crontab -l 2>/dev/null | grep "$BACKUP_SCRIPT_PATH" | while read -r line; do
        echo "-> $line"
    done || echo "No cron jobs found"
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

# منوی اصلی
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
    echo "1) Install / Setup"
    echo "2) Run Backup Now"
    echo "3) Settings"
    echo "4) Remove bot and cleanup"
    echo "5) Exit"
    echo "=============================="
    read -rp "Choose an option: " option
    case $option in
        1) setup_cron ;;
        2) run_backup ;;
        3) settings_menu ;;
        4) remove_bot ;;
        5) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    read -rp "Press enter to continue..."
}

if [[ "$1" == "--run" ]]; then
    run_backup
else
    while true; do show_menu; done
fi
