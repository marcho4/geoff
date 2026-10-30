#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source .venv/bin/activate
set -a; source .env; set +a

python3 yandex_email_parser.py
python3 telegram_messages_parser.py

TODAY=$(date +%F)
OUTPUT_DIR=$(realpath "$OUTPUT_DIR")
mkdir -p "${RESULTS_DIR:-./results}"
RESULTS_DIR=$(realpath "${RESULTS_DIR:-./results}")
SUMMARY="$RESULTS_DIR/summary_$TODAY.md"

if [ -f "$SUMMARY" ]; then
    echo "Сводка за $TODAY уже есть, пропускаю"
else
    rm -f "$SUMMARY.tmp"
    PROVIDER="${LLM_PROVIDER:-claude}"   # claude | gemini

    TASK="Ты готовишь ежедневный брифинг для студента магистратуры в стиле консалтинговых компаний. Сегодня $TODAY. Цель: студент за одну минуту понимает, что нужно сделать, и не пропускает ни одного дедлайна или изменения в учёбе.

        На входе письма и сообщения из Telegram за прошедшие сутки.

        ПРАВИЛА ОТБОРА
        1. Учебное: дедлайны, сдачи, контрольные, изменения расписания, переносы и отмены занятий, требования преподавателей, оценки, организационные решения по командам и проектам.
        2. Шум: рекламные рассылки, афиши, промо (Timepad и подобные), автоуведомления сервисов. В основные блоки шум не попадает никогда.
        3. Не выдумывай. Если дата, время или курс явно не указаны, пиши «дата не указана», не угадывай.
        4. Относительные даты («завтра», «в пятницу») переводи в абсолютные, исходя из даты сообщения.
        5. Если одна новость пришла из нескольких источников, объедини её в один пункт.

        СТРУКТУРА ОТВЕТА (строго в этом порядке)

        **Главное**
        1–2 предложения: самое важное за день и что сделать в первую очередь.

        **🔴 Срочно — действие нужно в ближайшие 3 дня**
        **🟡 Запланировать — дедлайны и события позже**
        **🟢 К сведению — изменения, не требующие действий**

        Формат каждого пункта:
        • ДД.ММ (дн), время — Курс: что произошло. → Действие: конкретный глагол + что сделать.
        Для блока «К сведению» строку «→ Действие» не пиши.
        Внутри блока сортируй по дате, ближайшее сверху. Каждый пункт не длиннее двух строк. Пустой блок: «Нет».

        **Прочее**
        Не больше 2 строк о внеучебных событиях, только если они действительно стоят внимания. Иначе блок не выводи.

        **Fun**
        2–3 коротких предложения: о чём болтали студенты и над чем шутили. Без имён.

        ОФОРМЛЕНИЕ
        Только жирные заголовки блоков и маркеры «•». Никаких таблиц, заголовков через #, вступлений и заключений. Деловой стиль: без вводных слов, канцелярита и пересказа переписки, только выводы."

    case "$PROVIDER" in
      claude)
        # Claude читает входные файлы из OUTPUT_DIR и может писать только в RESULTS_DIR
        (cd "$OUTPUT_DIR" && claude -p \
            "$TASK Файлы лежат в текущей папке. Запиши итоговую сводку в markdown в файл $SUMMARY.tmp." \
            --add-dir "$RESULTS_DIR" \
            --allowedTools "Read" "Edit(/$RESULTS_DIR/**)" \
            --permission-prompts none)
        ;;

      gemini)
        : "${GEMINI_API_KEY:?Не задан GEMINI_API_KEY}"
        GEMINI_MODEL="${GEMINI_MODEL:-gemini-flash-lite-latest}"

        # Склеиваем все файлы из OUTPUT_DIR с заголовками и упаковываем в JSON через jq
        RESPONSE=$(
          find "$OUTPUT_DIR" -maxdepth 1 -type f -print0 | sort -z |
            while IFS= read -r -d '' f; do
              printf '\n===== FILE: %s =====\n' "${f##*/}"
              cat "$f"
            done |
          jq -Rs --arg task "$TASK Ответь только текстом сводки в markdown, не оборачивай его в блок кода." '{
              systemInstruction: { parts: [{ text: $task }] },
              contents: [{ role: "user", parts: [{ text: . }] }]
          }' |
          curl -sS -X POST \
            "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent" \
            -H 'Content-Type: application/json' \
            -H "x-goog-api-key: $GEMINI_API_KEY" \
            --data-binary @-
        ) || { echo "Запрос к Gemini не удался"; exit 1; }

        if jq -e '.error' <<<"$RESPONSE" >/dev/null; then
            echo "Gemini вернул ошибку: $(jq -r '.error.message' <<<"$RESPONSE")"
            exit 1
        fi

        # Берём текст ответа, пропуская «мысли» модели, если они есть
        jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")' \
            <<<"$RESPONSE" > "$SUMMARY.tmp"
        ;;

      *)
        echo "Неизвестный LLM_PROVIDER: $PROVIDER (ожидается claude или gemini)"
        exit 1
        ;;
    esac

    [ -s "$SUMMARY.tmp" ] || { echo "$PROVIDER не записал сводку в $SUMMARY.tmp"; exit 1; }
    mv "$SUMMARY.tmp" "$SUMMARY"
fi

python3 send_summary.py "$SUMMARY" \
  || { echo "Не удалось отправить в Telegram"; exit 1; }
