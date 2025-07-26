#!/bin/bash

BACKUP_SCRIPT_PATH="/root/backup_marzban.sh"

# ذخیره اسکریپت بکاپ در فایل جداگانه با استفاده از Here-doc
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

function extract_password() {
    if [[ -f "$ENV_FILE" ]]; then
        grep "^MYSQL_ROOT_PASSWORD=" "$ENV_FILE" | head -n1 | cut -d "=" -f2- > "$PASS_FILE"
    else
        echo "$ENV_FILE not found!"
        exit 1
    fi
}

function backup_and_send() {
    if [[ -f "$PASS_FILE" ]]; then
        MYSQL_ROOT_PASSWORD=$(cat "$PASS_FILE" | tr -d "\r\n ")
    else
        echo "Password file $PASS_FILE not found."
        exit 1
    fi

    if [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        echo "Telegram Bot Token or Chat ID not set."
        exit 1
    fi

    mkdir -p "$DB_DIR" "$OPT_DIR" "$VARLIB_DIR"

    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzban > "$DB_DIR/marzban.sql"
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzhelp > "$DB_DIR/marzhelp.sql"

    tar -czf "$DB_DIR/db_backup.tar.gz" -C "$DB_DIR" marzban.sql marzhelp.sql
    rm -f "$DB_DIR/marzban.sql" "$DB_DIR/marzhelp.sql"

    if [[ -f "/opt/marzban/.env" && -f "/opt/marzban/docker-compose.yml" ]]; then
        tar -czf "$OPT_DIR/marzban_opt_backup.tar.gz" -C /opt/marzban .env docker-compose.yml
    fi

    if [[ -d "$VARLIB_SOURCE" ]]; then
        rsync -a --exclude="mysql" --exclude="xray-core" "$VARLIB_SOURCE/" "$VARLIB_DIR/"
        tar -czf "$VARLIB_DIR/varlib_backup.tar.gz" -C "$VARLIB_DIR" .
        find "$VARLIB_DIR" ! -name "varlib_backup.tar.gz" -type f -delete
        find "$VARLIB_DIR" ! -name "varlib_backup.tar.gz" -type d -empty -delete
    fi

    cd "$BASE_DIR" || exit 1
    FINAL_ARCHIVE="marzban_full_backup_$(date +'%Y%m%d_%H%M%S').tar.gz"
    rm -f marzban_full_backup_*.tar.gz
    tar -czf "$FINAL_ARCHIVE" db opt varlib

    response=$(curl -s -F chat_id="$TELEGRAM_CHAT_ID" \
      -F document=@"$BASE_DIR/$FINAL_ARCHIVE" \
      -F caption="Backup - $(date +'%Y-%m-%d %H:%M:%S')" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument")

    if echo "$response" | grep -q "\"ok\":true"; then
        echo "Backup sent successfully."
        rm -f "$BASE_DIR/$FINAL_ARCHIVE"
    else
        echo "Failed to send backup to Telegram."
        echo "Response: $response"
    fi
}

function setup_cron() {
    echo "Enter backup interval in hours (1-24):"
    read -r INTERVAL

    if ! [[ "$INTERVAL" =~ ^([1-9]|1[0-9]|2[0-4])$ ]]; then
        echo "Invalid input. Please enter a number between 1 and 24."
        exit 1
    fi

    CRON_EXPR="0 */$INTERVAL * * *"
    CRON_CMD="/bin/bash $BACKUP_SCRIPT_PATH --run >> /root/backup_marzban.log 2>&1"
    (crontab -l 2>/dev/null | grep -v -F "$CRON_CMD" ; echo "$CRON_EXPR $CRON_CMD") | crontab -

    echo "Cron job updated: runs every $INTERVAL hour(s)"
}

function run_backup() {
    [[ -f /root/.telegram_bot_token ]] && TELEGRAM_BOT_TOKEN=$(cat /root/.telegram_bot_token) || { echo "Token not found"; return 1; }
    [[ -f /root/.telegram_chat_id ]] && TELEGRAM_CHAT_ID=$(cat /root/.telegram_chat_id) || { echo "Chat ID not found"; return 1; }

    extract_password
    backup_and_send
}

function install_bot() {
    echo "Enter Telegram Bot Token:"
    read -r TELEGRAM_BOT_TOKEN
    echo "$TELEGRAM_BOT_TOKEN" > /root/.telegram_bot_token

    echo "Enter Telegram Chat ID:"
    read -r TELEGRAM_CHAT_ID
    echo "$TELEGRAM_CHAT_ID" > /root/.telegram_chat_id

    setup_cron
    run_backup
}

function show_settings() {
    while true; do
        clear
        echo "========== Bot Settings =========="
        echo "1) Show current Bot Token"
        echo "2) Change Bot Token"
        echo "3) Show current Chat ID"
        echo "4) Change Chat ID"
        echo "5) Show current Cron Job"
        echo "6) Change Cron Job"
        echo "7) Back to Main Menu"
        echo "=================================="
        echo -n "Select option: "
        read -r opt

        case $opt in
            1) echo "Current Bot Token:"
               cat /root/.telegram_bot_token ;;
            2) echo "Enter new Bot Token:"
               read -r TELEGRAM_BOT_TOKEN
               echo "$TELEGRAM_BOT_TOKEN" > /root/.telegram_bot_token
               echo "Updated." ;;
            3) echo "Current Chat ID:"
               cat /root/.telegram_chat_id ;;
            4) echo "Enter new Chat ID:"
               read -r TELEGRAM_CHAT_ID
               echo "$TELEGRAM_CHAT_ID" > /root/.telegram_chat_id
               echo "Updated." ;;
            5) echo "Current Cron Jobs:"
               crontab -l | grep "$BACKUP_SCRIPT_PATH" || echo "No cron job set." ;;
            6) setup_cron ;;
            7) break ;;
            *) echo "Invalid option." ;;
        esac
        echo "Press enter to continue..."; read
    done
}

function show_menu() {
    clear
    echo "=============================="
    echo " Marzban Backup Management Menu"
    echo "=============================="
    echo "1) Install/setup Telegram bot + cron (includes 1st backup)"
    echo "2) Run backup now"
    echo "3) Change cron job interval"
    echo "4) Settings"
    echo "5) Exit"
    echo "=============================="
    echo -n "Choose an option: "
    read -r option

    case $option in
        1) install_bot ;;
        2) run_backup ;;
        3) setup_cron ;;
        4) show_settings ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    echo "Press enter to continue..."
    read -r
}

if [[ "$1" == "--run" ]]; then
    run_backup
else
    while true; do
        show_menu
    done
fi
EOF

# اجازه اجرا به اسکریپت بکاپ
chmod +x "$BACKUP_SCRIPT_PATH"

# اجرای اسکریپت بکاپ (که منو دارد)
bash "$BACKUP_SCRIPT_PATH"
