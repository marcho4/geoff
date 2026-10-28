# Что лежит в references/

Скилл не пишет скрипты сам — он копирует их отсюда. Это рабочие версии с настроенного сервера; имена файлов должны совпадать с теми, что в SKILL.md.

| Файл | Где запускается | Назначение | Читает из env |
|---|---|---|---|
| `yandex_email_parser.py` | сервер | письма из INBOX за `HOURS_BACK` часов (по умолчанию 24) → `MAIL_OUTPUT` | `YANDEX_LOGIN`, `YANDEX_APP_PASSWORD`, `MAIL_OUTPUT`, `HOURS_BACK` |
| `telegram_messages_parser.py` | сервер | сообщения из папки Telegram за `HOURS_BACK` часов → `TG_OUTPUT`; использует готовую `tg_session.session`, не логинится | `TG_API_ID`, `TG_API_HASH`, `TG_FOLDER`, `TG_OUTPUT`, `TG_SESSION`, `HOURS_BACK` |
| `send_summary.py` | сервер | переводит markdown-сводку в HTML-разметку Telegram, режет на сообщения до 4000 знаков, при ошибке разметки шлёт простым текстом | `TG_BOT_TOKEN`, `TG_CHAT_ID` |
| `run.sh` | сервер, из cron | активирует venv, грузит `.env`, экспорт → сводка через `claude -p` в `RESULTS_DIR` (идемпотентно по дате) → `send_summary.py`; Telegram-экспорт пропускается, пока в `.env` нет `TG_API_ID` | всё выше + `OUTPUT_DIR`, `RESULTS_DIR` (по умолчанию `./results`) |
| `requirements.txt` | сервер | зафиксированные версии библиотек для venv (Telethon 1.45.0 и зависимости) | — |
| `tdata_to_session.py` | **ноутбук студента** | конвертирует `tdata` Telegram Desktop в `tg_session.session` через TGConvertor; сам ищет `tdata` для macOS/Windows/Linux | — |

Промпт сводки зашит в `run.sh`. Claude запускается в `OUTPUT_DIR` с правами только на `Read` и на `Edit` внутри `RESULTS_DIR`. Отдельных `digest_prompt.md` и `summarizer-*.md` нет; Codex и прямой API пока не поддерживаются.

Уроки, которые зашиты в SKILL.md и которые нельзя потерять при правках:
- Вход в Telegram по коду из Telethon/Pyrogram не работает — Telegram не доставляет коды сторонним клиентам. Только Telegram Desktop + TGConvertor.
- `opentele` не читает `tdata` современных версий — не предлагать.
- Telegram из App Store / Microsoft Store — не Desktop, `tdata` у него нет.
- cron не знает `PATH` и не активирует venv: `PATH=` первой строкой crontab, `source .venv/bin/activate` внутри `run.sh`, прогон через `env -i` перед добавлением в cron.
- `claude -p` без права на запись отвечает текстом в stdout вместо файла — поэтому `run.sh` проверяет, что `summary_ДАТА.md.tmp` не пустой, и падает с понятной ошибкой.
