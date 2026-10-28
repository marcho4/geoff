#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate
set -a; source .env; set +a

python3 yandex_email_parser.py
[ -z "${TG_API_ID:-}" ] || python3 telegram_messages_parser.py

TODAY=$(date +%F)
OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
mkdir -p "${RESULTS_DIR:-./results}"
RESULTS_DIR=$(realpath "${RESULTS_DIR:-./results}")
SUMMARY="$RESULTS_DIR/summary_$TODAY.md"

if [ -f "$SUMMARY" ]; then
    echo "Сводка за $TODAY уже есть, пропускаю"
else
    rm -f "$SUMMARY.tmp"
    # Claude читает входные файлы из OUTPUT_DIR и может писать только в RESULTS_DIR
    (cd "$OUTPUT_DIR" && claude -p "Составь саммаризацию по прошедшему дню на основе почты и сообщений из телеграма. Выдели важное и то, что требует действия. Файлы лежат в текущей папке. Запиши итоговую сводку в markdown в файл $SUMMARY.tmp." \
        --add-dir "$RESULTS_DIR" \
        --allowedTools "Read" "Edit(/$RESULTS_DIR/**)" \
        --permission-prompts none)
    [ -s "$SUMMARY.tmp" ] || { echo "Claude не записал сводку в $SUMMARY.tmp"; exit 1; }
    mv "$SUMMARY.tmp" "$SUMMARY"
fi

python3 send_summary.py "$SUMMARY" \
  || { echo "Не удалось отправить в Telegram"; exit 1; }
