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
        grep '^MYSQL_ROOT_PASSWORD=' "$ENV_FILE" | head -n1 | cut -d '=' -f2- > "$PASS_FILE"
        if [[ $? -eq 0 ]]; then
            echo "Password extracted and saved to $PASS_FILE"
        else
            echo "Failed to extract password"
            exit 1
        fi
    else
        echo "$ENV_FILE not found!"
        exit 1
    fi
}

function backup_and_send() {
    if [[ -f "$PASS_FILE" ]]; then
        MYSQL_ROOT_PASSWORD=$(cat "$PASS_FILE" | tr -d '\r\n ')
        if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
            echo "Password file is empty."
            exit 1
        fi
    else
        echo "Password file $PASS_FILE not found."
        exit 1
    fi

    if [[ -z "$TELEGRAM_BOT_TOKEN" ]] || [[ -z "$TELEGRAM_CHAT_ID" ]]; then
        echo "Telegram Bot Token or Chat ID not set."
        exit 1
    fi

    mkdir -p "$DB_DIR" "$OPT_DIR" "$VARLIB_DIR"

    echo "Starting backup..."

    echo "Backing up marzban database..."
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzban > "$DB_DIR/marzban.sql" || { echo "Failed to backup marzban database."; exit 1; }

    echo "Backing up marzhelp database..."
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$CONTAINER_NAME" mysqldump --no-defaults -u root marzhelp > "$DB_DIR/marzhelp.sql" || { echo "Failed to backup marzhelp database."; exit 1; }

    echo "Compressing database dumps..."
    tar -czf "$DB_DIR/db_backup.tar.gz" -C "$DB_DIR" marzban.sql marzhelp.sql
    rm -f "$DB_DIR/marzban.sql" "$DB_DIR/marzhelp.sql"

    echo "Backing up /opt/marzban files..."
    if [[ -f "/opt/marzban/.env" && -f "/opt/marzban/docker-compose.yml" ]]; then
        tar -czf "$OPT_DIR/marzban_opt_backup.tar.gz" -C /opt/marzban .env docker-compose.yml
    else
        echo "Warning: .env or docker-compose.yml not found in /opt/marzban"
    fi

    echo "Backing up /var/lib/marzban excluding mysql and xray-core..."
    if [[ -d "$VARLIB_SOURCE" ]]; then
        rsync -a --exclude='mysql' --exclude='xray-core' "$VARLIB_SOURCE/" "$VARLIB_DIR/"
        tar -czf "$VARLIB_DIR/varlib_backup.tar.gz" -C "$VARLIB_DIR" .
        find "$VARLIB_DIR" ! -name 'varlib_backup.tar.gz' -type f -delete
        find "$VARLIB_DIR" ! -name 'varlib_backup.tar.gz' -type d -empty -delete
    else
        echo "Directory $VARLIB_SOURCE does not exist!"
    fi

    echo "Creating final compressed archive..."
    cd "$BASE_DIR" || exit 1
    FINAL_ARCHIVE="marzban_full_backup_$(date +"%Y%m%d_%H%M%S").tar.gz"
    rm -f marzban_full_backup_*.tar.gz
    tar -czf "$FINAL_ARCHIVE" db opt varlib

    echo "Sending backup to Telegram..."
    response=$(curl -s -F chat_id="$TELEGRAM_CHAT_ID" \
      -F document=@"$BASE_DIR/$FINAL_ARCHIVE" \
      -F caption="Backup - $(date +"%Y-%m-%d %H:%M:%S") (.tar.gz)" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument")

    if echo "$response" | grep -q '"ok":true'; then
        echo "Backup sent successfully."
        rm -f "$BASE_DIR/$FINAL_ARCHIVE"
    else
        echo "Failed to send backup to Telegram."
        echo "Response: $response"
    fi

    echo "Backup process completed."
}

function setup_cron() {
    echo "Enter the Telegram Bot Token:"
    read -r TELEGRAM_BOT_TOKEN
    echo "Enter the Telegram Chat ID:"
    read -r TELEGRAM_CHAT_ID

    echo "$TELEGRAM_BOT_TOKEN" > /root/.telegram_bot_token
    echo "$TELEGRAM_CHAT_ID" > /root/.telegram_chat_id

    echo "Enter backup interval in hours (1-24):"
    read -r INTERVAL

    if ! [[ "$INTERVAL" =~ ^([1-9]|1[0-9]|2[0-4])$ ]]; then
        echo "Invalid input. Please enter a number between 1 and 24."
        exit 1
    fi

    CRON_EXPR="0 */$INTERVAL * * *"
    CRON_CMD="/bin/bash $0 --run >> /root/backup_marzban.log 2>&1"

    (crontab -l 2>/dev/null | grep -v -F "$CRON_CMD" ; echo "$CRON_EXPR $CRON_CMD") | crontab -

    echo "Cron job installed: runs every $INTERVAL hour(s)"
    echo "Check logs in /root/backup_marzban.log"
}

# اجرای اسکریپت
if [[ "$1" == "--run" ]]; then
    [[ -f /root/.telegram_bot_token ]] && TELEGRAM_BOT_TOKEN=$(cat /root/.telegram_bot_token) || { echo "Telegram Bot Token file not found!"; exit 1; }
    [[ -f /root/.telegram_chat_id ]] && TELEGRAM_CHAT_ID=$(cat /root/.telegram_chat_id) || { echo "Telegram Chat ID file not found!"; exit 1; }

    extract_password
    backup_and_send
else
    extract_password
    setup_cron
    echo "Running backup now..."
    backup_and_send
fi
