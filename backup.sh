function setup_cron() {
    echo "Enter the backup interval in hours (1-24):"
    read -r INTERVAL

    if ! [[ "$INTERVAL" =~ ^([1-9]|1[0-9]|2[0-4])$ ]]; then
        echo "Invalid input. Please enter a number between 1 and 24."
        return 1
    fi

    CRON_EXPR="0 */$INTERVAL * * *"
    CRON_CMD="/bin/bash $BACKUP_SCRIPT_PATH --run >> /root/backup_marzban.log 2>&1"

    (crontab -l 2>/dev/null | grep -v -F "$CRON_CMD" ; echo "$CRON_EXPR $CRON_CMD") | crontab -

    echo "Cron job installed: runs every $INTERVAL hour(s)"
    echo "Check logs in /root/backup_marzban.log"
}

function install_bot() {
    echo "Installing bot and setting up cron job..."

    echo "Enter the Telegram Bot Token:"
    read -r TELEGRAM_BOT_TOKEN
    echo "$TELEGRAM_BOT_TOKEN" > /root/.telegram_bot_token

    echo "Enter the Telegram Chat ID:"
    read -r TELEGRAM_CHAT_ID
    echo "$TELEGRAM_CHAT_ID" > /root/.telegram_chat_id

    # اگر نیاز بود، می‌توان Bot ID را هم اضافه کرد
    echo "Enter the Telegram Bot ID (optional):"
    read -r TELEGRAM_BOT_ID
    echo "$TELEGRAM_BOT_ID" > /root/.telegram_bot_id

    setup_cron

    echo "Performing initial backup now..."
    run_backup
}

function show_settings_menu() {
    while true; do
        clear
        echo "=============================="
        echo "     Bot Settings Menu"
        echo "=============================="
        echo "1) Show current Telegram Bot Token"
        echo "2) Change Telegram Bot Token"
        echo "3) Show current Telegram Chat ID"
        echo "4) Change Telegram Chat ID"
        echo "5) Show current Telegram Bot ID"
        echo "6) Change Telegram Bot ID"
        echo "7) Change Cron Job Interval"
        echo "8) Back to main menu"
        echo "=============================="
        echo -n "Choose an option: "
        read -r opt

        case $opt in
            1) echo "Current Telegram Bot Token:"
               cat /root/.telegram_bot_token
               ;;
            2) echo "Enter new Telegram Bot Token:"
               read -r TELEGRAM_BOT_TOKEN
               echo "$TELEGRAM_BOT_TOKEN" > /root/.telegram_bot_token
               echo "Bot Token updated."
               ;;
            3) echo "Current Telegram Chat ID:"
               cat /root/.telegram_chat_id
               ;;
            4) echo "Enter new Telegram Chat ID:"
               read -r TELEGRAM_CHAT_ID
               echo "$TELEGRAM_CHAT_ID" > /root/.telegram_chat_id
               echo "Chat ID updated."
               ;;
            5) echo "Current Telegram Bot ID:"
               cat /root/.telegram_bot_id
               ;;
            6) echo "Enter new Telegram Bot ID:"
               read -r TELEGRAM_BOT_ID
               echo "$TELEGRAM_BOT_ID" > /root/.telegram_bot_id
               echo "Bot ID updated."
               ;;
            7) setup_cron ;;
            8) break ;;
            *) echo "Invalid option. Try again." ;;
        esac
        echo "Press enter to continue..."
        read -r
    done
}

function show_menu() {
    clear
    echo "=============================="
    echo " Marzban Backup Management Menu"
    echo "=============================="
    echo "1) Install/setup Telegram bot and cron job (initial backup included)"
    echo "2) Run backup now and send to Telegram"
    echo "3) Change cron job interval"
    echo "4) Bot settings"
    echo "5) Exit"
    echo "=============================="
    echo -n "Choose an option: "
    read -r option

    case $option in
        1) install_bot ;;
        2) run_backup ;;
        3) setup_cron ;;
        4) show_settings_menu ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Please try again." ;;
    esac
    echo "Press enter to continue..."
    read -r
}
