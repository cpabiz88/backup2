#!/usr/bin/env bash

# =====================================================================
# backup.sh v1.5 — бэкап + email + Telegram
# Конфиг: /etc/backup.conf
# =====================================================================

set -o errexit
set -o nounset
set -o pipefail

# -----------------------------------------------------------------------------
# 1. Загрузка конфигурационного файла
# -----------------------------------------------------------------------------
CONFIG_FILE="/etc/backup.krist/backup.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ОШИБКА: файл конфигурации $CONFIG_FILE не найден." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. Подготовка временного лога и очистка при выходе
# -----------------------------------------------------------------------------
TMP_LOG=$(mktemp /tmp/backup_run_XXXXXX.log)
trap 'rm -f "$TMP_LOG"' EXIT

# -----------------------------------------------------------------------------
# 3. Функция логирования (в общий лог и во временный)
# -----------------------------------------------------------------------------
log_message() {
    local MSG="$1"
    local TS
    TS=$(date '+%F в %T')
    echo "${TS}: ${MSG}" >> "$LOG_FILE"
    echo "${TS}: ${MSG}" >> "$TMP_LOG"
}

# -----------------------------------------------------------------------------
# 4. Отправка email-уведомления об ошибках (если включено)
# -----------------------------------------------------------------------------
send_email_alert() {
    local TXT="$1"
    if [[ "${EMAIL_NOTIFICATION_ENABLE:-0}" -eq 1 ]]; then
        if echo "$TXT" | mail -s "Ошибка резервного копирования" "$EMAIL_NOTIFICATION"; then
            log_message "Email-уведомление отправлено на $EMAIL_NOTIFICATION"
        else
            log_message "ОШИБКА: не удалось отправить Email на $EMAIL_NOTIFICATION"
        fi
    fi
}

# -----------------------------------------------------------------------------
# 5. Отправка итогового лога в Telegram (если включено)
# -----------------------------------------------------------------------------
send_telegram_log() {
    # Если выключены — выходим
    if [[ "${TELEGRAM_NOTIFICATION_ENABLE:-0}" -ne 1 ]]; then
        log_message "Telegram-уведомления отключены"
        return
    fi

    # Достаём последние 100 строк временного лога
    local BODY
    BODY=$(tail -n100 "$TMP_LOG")

    # Добавляем пустую строку после ``` и перед ```
    local PAYLOAD
    PAYLOAD=$'```\n'
    PAYLOAD+="${BODY}"
    PAYLOAD+=$'\n```'

    for CHAT in ${TELEGRAM_CHAT_IDS}; do
        if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -d chat_id="$CHAT" \
                -d parse_mode="Markdown" \
                -d text="$PAYLOAD" \
                >/dev/null; then
            log_message "Telegram-уведомление отправлено в чат $CHAT"
        else
            log_message "ОШИБКА: не удалось отправить Telegram-уведомление в чат $CHAT"
        fi
    done
}
# -----------------------------------------------------------------------------
# 6. Подготовка директорий назначения и проверка свободного места
# -----------------------------------------------------------------------------
prepare_backup_dirs() {
    for D in ${BACKUP_DIRS}; do
        if [[ ! -d "$D" ]]; then
            if mkdir -p "$D"; then
                log_message "Создана директория $D"
            else
                log_message "ОШИБКА: не удалось создать директорию $D"
                exit 1
            fi
        fi

        local AVAIL
        AVAIL=$(df --output=avail "$D" | tail -n1)
        if (( AVAIL < MINIMUM_FREE_SPACE )); then
            log_message "Недостаточно места в $D: ${AVAIL} KB < ${MINIMUM_FREE_SPACE} KB"
            exit 1
        fi
    done
}

# -----------------------------------------------------------------------------
# 7. Удаление старых архивов
# -----------------------------------------------------------------------------
delete_old_backups() {
    for D in ${BACKUP_DIRS}; do
        log_message "Удаление архивов старше ${RETENTION_DAYS} дней в $D"
        if find "$D" -type f -name '*.tar.gz' -mtime +"${RETENTION_DAYS}" -exec rm -f {} \;; then
            log_message "Старые архивы удалены в $D"
        else
            # send_email_alert "ОШИБКА: не удалось удалить старые архивы в $D"
            log_message "Не найдены старые архивы для удаления"
        fi
    done
}

# -----------------------------------------------------------------------------
# 8. Сжатие старых логов
# -----------------------------------------------------------------------------
compress_old_logs() {
    local LD LB
    LD=$(dirname "$LOG_FILE")
    LB=$(basename "$LOG_FILE")
    log_message "Сжатие логов старше ${RETENTION_DAYS} дней в $LD"
    if find "$LD" -type f -name "${LB}*" -mtime +"${RETENTION_DAYS}" -exec gzip {} \;; then
        log_message "Старые логи сжаты в $LD"
    else
        # send_email_alert "ОШИБКА: не удалось сжать логи в $LD"
        log_message "Не найдены старые логи для сжатия"
    fi
}

# -----------------------------------------------------------------------------
# 9. Резервное копирование одной директории (SRC → DST)
# -----------------------------------------------------------------------------
perform_backup() {
    local SRC="$1"
    local DST="$2"

    if [[ ! -d "$SRC" ]]; then
#        send_email_alert "ОШИБКА: исходная директория не найдена: $SRC"
                                log_message "ОШИБКА: Исходная директория не найдена $SRC"
        return
    fi

    local TS NAME ARCH
    TS=$(date '+%F.%T')
    NAME=$(basename "$SRC")
    ARCH="${TS}-${NAME}.tar.gz"

    log_message "Архивация директории $SRC → $DST/$ARCH"
    if tar -czf "${DST}/${ARCH}" "$SRC" 2>>"$LOG_FILE"; then
        log_message "Создан архив ${ARCH} в $DST"
    else
#        send_email_alert "ОШИБКА: не удалось заархивировать ${SRC} в ${DST}"
        log_message "ОШИБКА: не удалось заархивировать ${SRC} в ${DST}"
    fi
}

# -----------------------------------------------------------------------------
# 10. Основной блок
# -----------------------------------------------------------------------------
log_message "=== НАЧАЛО РЕЗЕРВНОГО КОПИРОВАНИЯ НА СЕРВЕРЕ SAMBA ==="

log_message "Архивация из: $DIRECTORIES_TO_BACKUP"
log_message "Архивация в: $BACKUP_DIRS"

prepare_backup_dirs

# Параллельное архивирование: для каждой пары SRC×DST
for DST in ${BACKUP_DIRS}; do
    for SRC in ${DIRECTORIES_TO_BACKUP}; do
        perform_backup "$SRC" "$DST" &
    done
done
wait

delete_old_backups
compress_old_logs

log_message "=== ЗАВЕРШЕНО РЕЗЕРВНОЕ КОПИРОВАНИЕ ==="

# Отправляем итоговый лог в Telegram (если включено)
send_telegram_log

exit 0
