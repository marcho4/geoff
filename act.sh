#!/bin/bash
# Активный режим Джеффа.
#
#   ./act.sh              полный прогон: календарь дат → триаж → задачи → отправка черновиков
#   ./act.sh task <dir>   обработать одну задачу (вызывается полным прогоном)
#
# Берёт выгрузку из $OUTPUT_DIR, которую уже сделал run.sh.
#
# Настройки (.env, всё необязательно):
#   LLM_PROVIDER        общий провайдер сводки и агентов: claude | codex
#   CODEX_MODEL         общая модель Codex (по умолчанию модель CLI)
#   AGENT_MODEL         модель Claude (по умолчанию модель CLI)
#   MAX_TASKS=3         сколько задач брать за прогон
#   MAX_ROUNDS=2        кругов «ревью → валидация → правки» на задачу
#   AGENT_BUDGET_USD=1  лимит на один вызов агента
#   REVIEWER2_PROVIDER  claude | codex — кто проверяет качество (второй ревьюер)
#   DRY_RUN=1           ничего не отправлять в Telegram и не записывать задачи в реестр
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)
set -a; source .env; set +a

TODAY=$(date +%F)
OUT=$(realpath "${OUTPUT_DIR:-./out}")
AGENTS="$ROOT/agents"
STATE="$ROOT/state"            # календарь дат и его история
TASKS="$ROOT/tasks"            # папка на каждую задачу + реестр index.json
DATES_JSON="$STATE/dates.json"
DATES_MD="$STATE/dates.md"
INDEX="$TASKS/index.json"
MAX_TASKS=${MAX_TASKS:-3}
MAX_ROUNDS=${MAX_ROUNDS:-2}
BUDGET=${AGENT_BUDGET_USD:-1}
PROVIDER=${LLM_PROVIDER:-claude}
REVIEWER2=${REVIEWER2_PROVIDER:-$PROVIDER}
case "$PROVIDER" in claude|codex) ;; *) echo "Агенты не поддерживают LLM_PROVIDER=$PROVIDER" >&2; exit 2 ;; esac
case "$REVIEWER2" in claude|codex) ;; *) echo "Неизвестный REVIEWER2_PROVIDER=$REVIEWER2" >&2; exit 2 ;; esac
DRY_RUN=${DRY_RUN:-0}

log() { echo "[act $(date +%T)] $*" >&2; }

# ---------- вызовы агентов ----------

claude_run() {
  claude -p "$@" ${AGENT_MODEL:+--model "$AGENT_MODEL"} \
    --strict-mcp-config --max-budget-usd "$BUDGET" --permission-prompts none
}

# agent_ok <raw.json>: вызов агента с инструментами завершился без ошибки
agent_ok() {
  local response
  response=$(cat "$1")
  jq -e '.is_error != true' <<<"$response" >/dev/null 2>&1 || {
    log "агент вернул ошибку: $(jq -r '.result // "нет вывода"' <<<"$response" 2>/dev/null | head -c 200)"
    return 1
  }
}

system_prompt() { cat "$AGENTS/_guard.md"; echo; cat "$AGENTS/$1.md"; }

# ask <агент> <схема> [raw-лог]: данные со stdin → JSON по схеме в stdout. Без инструментов.
ask() {
  local agent=$1 schema=$2 raw_log=${3:-/dev/null} raw
  if [ "${ASK_PROVIDER:-$PROVIDER}" = codex ]; then
    ask_codex "$agent" "$schema" "$raw_log"
    return $?
  fi
  raw=$(claude_run "Входные данные ниже. Сегодня $TODAY." \
    --tools "" \
    --append-system-prompt "$(system_prompt "$agent")" \
    --output-format json --json-schema "$(cat "$AGENTS/schemas/$schema.json")")
  printf '%s\n' "$raw" > "$raw_log"
  agent_ok /dev/stdin <<<"$raw" || return 1
  jq -e '.structured_output // error("агент '"$agent"' не вернул structured_output")' <<<"$raw"
}

# Codex получает все данные через stdin и возвращает результат без инструментов.
ask_codex() {
  local agent=$1 schema=$2 raw_log=${3:-/dev/null} tmp rc=0
  tmp=$(mktemp)
  codex exec --cd "$PWD" --sandbox read-only --skip-git-repo-check --ephemeral --color never \
    ${CODEX_MODEL:+--model "$CODEX_MODEL"} \
    --output-schema "$AGENTS/schemas/$schema.json" --output-last-message "$tmp" \
    "$(system_prompt "$agent") Сегодня $TODAY. Входные данные переданы в блоке <stdin>, ничего не запускай." \
    >/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    jq -n --slurpfile output "$tmp" '{is_error: false, structured_output: $output[0]}' > "$raw_log" || rc=$?
    if [ "$rc" -eq 0 ]; then jq -e . "$tmp" || rc=$?; fi
  else
    jq -n --argjson rc "$rc" '{is_error: true, result: ("codex exec exited with " + ($rc|tostring))}' > "$raw_log"
  fi
  rm -f "$tmp"
  return "$rc"
}

# Генерация текста без доступа к файлам, секретам и внешним действиям.
codex_draft() {
  local agent=$1 raw_log=$2 tmp rc=0
  tmp=$(mktemp)
  { for f in task.json dates.md draft.md accepted.json; do
      if [ -f "$f" ]; then printf '\n<%s>\n' "$f"; cat "$f"; printf '\n</%s>\n' "$f"; fi
    done
    if [ "$agent" = executor ]; then bundle_messages; fi
  } | codex exec --cd "$PWD" --sandbox read-only --skip-git-repo-check --ephemeral --color never \
    ${CODEX_MODEL:+--model "$CODEX_MODEL"} --output-last-message "$tmp" \
    "$(system_prompt "$agent") Все файлы переданы в stdin. Ничего не запускай и не записывай. Верни только полный текст draft.md без обёртки блока кода." \
    >/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv "$tmp" draft.md
    jq -n '{is_error: false}' > "$raw_log"
  else
    rm -f "$tmp"
    jq -n '{is_error: true, result: "Codex не создал черновик"}' > "$raw_log"
    return 1
  fi
}

# ---------- Telegram ----------

tg_text() {
  [ "$DRY_RUN" = 1 ] && { log "DRY_RUN, сообщение: $1"; return; }
  curl -sS -f -o /dev/null "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT_ID" --data-urlencode "text=$1"
}

tg_file() {  # tg_file <путь> <имя файла> <подпись>
  [ "$DRY_RUN" = 1 ] && { log "DRY_RUN, файл $1 ($2)"; return; }
  curl -sS -f -o /dev/null "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" \
    --form-string "chat_id=$TG_CHAT_ID" \
    -F "document=@$1;filename=$2" \
    --form-string "caption=${3:0:1000}"
}

# ---------- данные ----------

bundle_messages() {
  find "$OUT" -maxdepth 1 -type f -name '*.json' -print0 | sort -z |
    while IFS= read -r -d '' f; do
      printf '\n===== FILE: %s =====\n' "${f##*/}"
      cat "$f"
    done
}

render_dates() {
  python3 - "$DATES_JSON" "$TODAY" > "$DATES_MD.tmp" <<'PY'
import json, sys, datetime as dt
events = json.load(open(sys.argv[1], encoding="utf-8"))["events"]
today = dt.date.fromisoformat(sys.argv[2])
WD = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]
ICON = {"deadline": "⏰", "exam": "📝", "defense": "🎤", "schedule_change": "🔁", "event": "📌", "other": "•"}
MARK = {"moved": " _(перенесено)_", "tentative": " _(предварительно)_", "cancelled": " _(отменено)_", "active": ""}

def line(e):
    when = ""
    if e["date"]:
        d = dt.date.fromisoformat(e["date"])
        when = f"**{d:%d.%m} ({WD[d.weekday()]})" + (f", {e['time']}" if e["time"] else "") + "** — "
    text = f"{e['course']}: {e['title']}"
    if e["status"] == "cancelled":
        text = f"~~{text}~~"
    note = f". {e['note']}" if e["note"] else ""
    return f"- {ICON.get(e['kind'], '•')} {when}{text}{MARK[e['status']]}{note} · {e['source']}"

groups = {"🔴 Ближайшие 7 дней": [], "🟡 Позже": [], "❔ Дата не указана": [], "✔️ Прошедшие (14 дней)": []}
for e in events:
    if not e["date"]:
        groups["❔ Дата не указана"].append(e)
        continue
    delta = (dt.date.fromisoformat(e["date"]) - today).days
    key = "✔️ Прошедшие (14 дней)" if delta < 0 else "🔴 Ближайшие 7 дней" if delta <= 7 else "🟡 Позже"
    groups[key].append(e)

print(f"# Важные даты\n\nОбновлено: {today:%d.%m.%Y}\n")
for title, items in groups.items():
    print(f"## {title}\n")
    print("\n".join(line(e) for e in items) if items else "Нет")
    print()
PY
  mv "$DATES_MD.tmp" "$DATES_MD"
}

update_dates() {
  log "обновляю календарь дат"
  local new old_n new_n cutoff
  new=$( { echo "<current_dates>"; cat "$DATES_JSON"; echo "</current_dates>"
           echo "<messages>"; bundle_messages; echo "</messages>"; } |
         ask dates dates "$STATE/history/dates_${TODAY}.raw.json" )

  # Защита от потери календаря: агент обязан вернуть старые записи
  old_n=$(jq --arg t "$TODAY" '[.events[] | select(.date == null or .date >= $t)] | length' "$DATES_JSON")
  new_n=$(jq --arg t "$TODAY" '[.events[] | select(.date == null or .date >= $t)] | length' <<<"$new")
  if [ "$old_n" -gt 0 ] && [ "$new_n" -lt $(( old_n / 2 )) ]; then
    log "агент вернул $new_n будущих дат вместо $old_n — календарь не трогаю"
    return
  fi

  cp "$DATES_JSON" "$STATE/history/dates_${TODAY}.before.json"
  cutoff=$(date -d "$TODAY -14 days" +%F)
  jq --arg c "$cutoff" '.events |= (map(select(.date == null or .date >= $c))
                                    | sort_by(.date // "9999-99-99", .time // ""))' \
    <<<"$new" > "$DATES_JSON.tmp"
  mv "$DATES_JSON.tmp" "$DATES_JSON"
  render_dates
  log "в календаре $(jq '.events | length' "$DATES_JSON") записей → $DATES_MD"
}

# ---------- одна задача (отдельный процесс, чтобы set -e работал внутри) ----------

run_task() {
  local dir=$1 r status=unverified bundle issues verdict accepted count majors cost
  cd "$dir"
  local deny=("Read(/$ROOT/.env)" "Read(/$ROOT/*.session)")

  log "$(jq -r .title task.json): проверка на промпт-инъекции"
  local rc=0
  check_injection || rc=$?
  case $rc in
    0) ;;
    1) jq -n '{status: "blocked", rounds: 0, cost_usd: 0}' > result.json; exit 0 ;;
    *) log "проверка на инъекции не удалась — задачу не выполняю"; exit 1 ;;
  esac

  log "$(jq -r .title task.json): проверяю достаточность исходных данных"
  { echo "<task>"; cat task.json; echo "</task>"
    echo "<dates>"; cat dates.md; echo "</dates>"
    echo "<messages>"; bundle_messages; echo "</messages>"
  } | ask context_check context_check context_check.raw.json > context_check.json || {
    log "проверка данных не удалась — черновик не создаю"
    exit 1
  }
  jq -e '(.sufficient | type == "boolean") and (.reason | type == "string")
         and (.missing | type == "array") and all(.missing[]; type == "string")' \
      context_check.json >/dev/null || { log "некорректный ответ проверки данных"; exit 1; }
  if ! jq -e '.sufficient' context_check.json >/dev/null; then
    jq -n --arg reason "$(jq -r .reason context_check.json)" \
      --argjson missing "$(jq .missing context_check.json)" \
      '{status: "insufficient_context", rounds: 0, cost_usd: 0, reason: $reason, missing: $missing}' > result.json
    log "пропускаю задачу: $(jq -r .reason context_check.json)"
    exit 0
  fi

  log "$(jq -r .title task.json): исполнитель"
  if [ "$PROVIDER" = codex ]; then
    codex_draft executor executor.raw.json || exit 1
  else
  claude_run "Выполни задачу из task.json и запиши черновик в draft.md. Выгрузка писем и сообщений: $OUT" \
    --tools "Read,Write,Edit" --add-dir "$OUT" \
    --allowedTools "Read(/$dir/**)" "Read(/$OUT/**)" "Edit(/$dir/draft.md)" \
    --disallowedTools "${deny[@]}" \
    --append-system-prompt "$(system_prompt executor)" \
    --output-format json > executor.raw.json || true
  fi
  agent_ok executor.raw.json || exit 1
  [ -s draft.md ] || { log "исполнитель не создал draft.md"; exit 1; }

  # Дальше черновик уже есть: при сбое ревью или правок отправляем то, что успели (status=incomplete).
  # Каждый вызов проверяется явно — внутри цикла с break set -e не спасает.

  for r in $(seq 1 "$MAX_ROUNDS"); do
    bundle=$(printf '<task>\n%s\n</task>\n<dates>\n%s\n</dates>\n<draft>\n%s\n</draft>\n' \
      "$(cat task.json)" "$(cat dates.md)" "$(cat draft.md)")

    log "круг $r: ревью"
    ask reviewer_facts review "r${r}_facts.raw.json" <<<"$bundle" > "r${r}_facts.json" \
      || { status=incomplete; break; }
    ASK_PROVIDER="$REVIEWER2" ask reviewer_quality review "r${r}_quality.raw.json" <<<"$bundle" > "r${r}_quality.json" \
      || { status=incomplete; break; }

    issues=$(jq -s '([.[0].issues[] | . + {from: "facts"}] + [.[1].issues[] | . + {from: "quality"}])
                    | to_entries | map(.value + {n: (.key + 1)})' "r${r}_facts.json" "r${r}_quality.json")
    if [ "$(jq length <<<"$issues")" -eq 0 ]; then status=ok; break; fi

    log "круг $r: валидатор ($(jq length <<<"$issues") замечаний)"
    verdict=$( { echo "$bundle"; echo "<issues>"; echo "$issues"; echo "</issues>"; } |
               ask validator validate "r${r}_validate.raw.json" ) || { status=incomplete; break; }
    echo "$verdict" > "r${r}_validate.json"
    accepted=$(jq -n --argjson i "$issues" --argjson v "$verdict" \
      '[$v.decisions[] | select(.accept) as $d
        | ($i[] | select(.n == $d.n)) + {severity: $d.severity, reason: $d.reason}]')
    echo "$accepted" > "r${r}_accepted.json"
    count=$(jq length <<<"$accepted")
    majors=$(jq '[.[] | select(.severity == "major")] | length' <<<"$accepted")
    if [ "$count" -eq 0 ]; then status=ok; break; fi

    log "круг $r: правки (принято $count, из них major $majors)"
    cp draft.md "draft_before_r${r}.md"
    cp "r${r}_accepted.json" accepted.json
    if [ "$PROVIDER" = codex ]; then
      codex_draft fixer "r${r}_fix.raw.json" || { status=incomplete; break; }
    else
    claude_run "Исправь draft.md по замечаниям из accepted.json." \
      --tools "Read,Write,Edit" \
      --allowedTools "Read(/$dir/**)" "Edit(/$dir/draft.md)" \
      --disallowedTools "${deny[@]}" \
      --append-system-prompt "$(system_prompt fixer)" \
      --output-format json > "r${r}_fix.raw.json" || true
    fi
    agent_ok "r${r}_fix.raw.json" || { status=incomplete; break; }

    # Только мелкие правки — повторно не проверяем
    if [ "$majors" -eq 0 ]; then status=ok; break; fi
    status=unverified
  done

  cost=$(for f in ./*.raw.json; do jq -r '.total_cost_usd // 0' "$f" 2>/dev/null || echo 0; done |
         awk '{s += $1} END {printf "%.2f", s}')
  jq -n --arg s "$status" --argjson r "$r" --argjson c "$cost" \
    '{status: $s, rounds: $r, cost_usd: $c}' > result.json
  log "готово: $status, кругов $r, \$$cost"
}

# Дешёвый первый слой: регулярки по известным шаблонам атак. Только подсказка для агента.
PI_PATTERNS='ignore (all |the )?(previous|prior|above)|disregard .*instructions|system prompt|developer mode|you are now|act as|jailbreak|игнорир|забудь (все|предыдущ)|ты теперь|системн(ый|ого) промпт|инструкци[ия] (для|к) (ии|ассистент|бот|модел)|как языков(ая|ой) модел|<\/?(system|instructions?|assistant)>|\[/?INST\]|\.env|api[_ -]?key|парол|token|base64|curl |wget |rm -rf|[A-Za-z0-9+/]{120,}={0,2}|[\x{200B}-\x{200F}\x{2060}\x{FEFF}]'

# check_injection: 0 — можно выполнять, 1 — заблокирована (вердикт в injection.json), 2 — проверка не удалась
check_injection() {
  local hits verdict
  hits=$(jq -r '[.title, .goal, .source, .source_quote, .context] | join("\n")' task.json |
         LC_ALL=C.UTF-8 grep -oiP "$PI_PATTERNS" | sort -u | head -20 || true)
  verdict=$( { echo "<task>"; cat task.json; echo "</task>"
               echo "<prefilter>"; echo "${hits:-совпадений нет}"; echo "</prefilter>"; } |
             ask injection_check injection injection.raw.json ) || return 2
  echo "$verdict" > injection.json
  log "вердикт: $(jq -r .verdict <<<"$verdict")${hits:+ (регулярки: $(tr '\n' ' ' <<<"$hits"))}"
  [ "$(jq -r .verdict <<<"$verdict")" = safe ]
}

deliver() {  # deliver <dir> <status>
  local dir=$1 status=$2 title source deadline cost mark name
  title=$(jq -r .title "$dir/task.json")
  source=$(jq -r .source "$dir/task.json")
  deadline=$(jq -r '.deadline // "не указан"' "$dir/task.json")

  if [ "$status" = insufficient_context ]; then
    log "черновик $title не готовился: недостаточно исходных данных (см. $dir/context_check.json)"
    return
  fi
  if [ "$status" = blocked ]; then
    tg_text "$(jq -r --arg t "$title" --arg src "$source" '
      (if .verdict == "injection" then "🛑 Похоже на промпт-инъекцию" else "⚠️ Подозрительная задача" end)
      + ", черновик не готовил.\nЗадача: \($t)\nИсточник: \($src)\n\(.summary)"
      + ([.findings[:3][] | "\n• «\(.quote[:200])» — \(.reason)"] | join(""))' "$dir/injection.json")" || true
    return
  fi
  if [ "$status" = failed ]; then
    tg_text "❌ Джефф не смог подготовить черновик: $title ($source). Логи: $dir" || true
    return
  fi
  cost=$(jq -r .cost_usd "$dir/result.json")
  case $status in
    ok)         mark="✅ Проверено ревьюерами" ;;
    incomplete) mark="⚠️ Проверка прервалась на круге $(jq -r .rounds "$dir/result.json") (ошибка агента) — черновик мог остаться недоработанным" ;;
    *)          mark="⚠️ Серьёзные правки после ревью повторно не проверены" ;;
  esac
  name="$(sed 's#[/\\:*?"<>|;]#_#g' <<<"$title").md"
  tg_file "$dir/draft.md" "$name" "$(printf '📝 %s\nИсточник: %s\nДедлайн: %s\n%s · $%s' \
    "$title" "$source" "$deadline" "$mark" "$cost")"
}

# ---------- полный прогон ----------

main() {
  mkdir -p "$STATE/history" "$TASKS"
  exec 9>"$STATE/.lock"
  flock -n 9 || { log "уже запущен, выхожу"; exit 0; }
  [ -s "$DATES_JSON" ] || echo '{"events":[]}' > "$DATES_JSON"
  [ -s "$INDEX" ] || echo '[]' > "$INDEX"
  [ -s "$DATES_MD" ] || render_dates

  if [ "${1:-}" != tasks ]; then update_dates; fi
  if [ "${1:-}" = calendar ]; then return; fi

  log "триаж"
  local done_list triage task quote id dir status
  done_list=$(jq -c --arg s "$(date -d "$TODAY -60 days" +%F)" \
    '[.[] | select(.date >= $s) | {date, title, type, source}]' "$INDEX")
  triage=$( { echo "Лимит задач: $MAX_TASKS"
              echo "<dates>"; cat "$DATES_MD"; echo "</dates>"
              echo "<done>"; echo "$done_list"; echo "</done>"
              echo "<messages>"; bundle_messages; echo "</messages>"; } |
            ask triage triage "$STATE/history/triage_${TODAY}.raw.json" )
  log "найдено задач: $(jq '.tasks | length' <<<"$triage")"

  while IFS= read -r task <&3; do
    # id задачи = хэш цитаты-источника: одно и то же сообщение не превратится в задачу дважды
    quote=$(jq -r .source_quote <<<"$task")
    id=$(printf '%s' "$quote" | tr -s '[:space:]' ' ' | sha1sum | cut -c1-10)
    if jq -e --arg id "$id" 'any(.[]; .id == $id)' "$INDEX" >/dev/null; then
      log "задача $id уже была, пропускаю"
      continue
    fi

    dir="$TASKS/${TODAY}_$id"
    mkdir -p "$dir"
    jq --arg id "$id" '. + {id: $id}' <<<"$task" > "$dir/task.json"
    cp "$DATES_MD" "$dir/dates.md"

    if "$0" task "$dir" </dev/null; then
      status=$(jq -r .status "$dir/result.json")
    else
      status=failed
    fi
    deliver "$dir" "$status" || log "не удалось отправить $dir в Telegram"

    if [ "$DRY_RUN" != 1 ] && [ "$status" != insufficient_context ]; then
      jq --argjson t "$(cat "$dir/task.json")" --arg d "$TODAY" --arg s "$status" \
         --arg dir "${dir#"$ROOT"/}" \
        '. + [{id: $t.id, date: $d, title: $t.title, type: $t.type, source: $t.source,
               deadline: $t.deadline, status: $s, dir: $dir}]' "$INDEX" > "$INDEX.tmp"
      mv "$INDEX.tmp" "$INDEX"
    fi
  done 3< <(jq -c --argjson n "$MAX_TASKS" '.tasks[:$n][]' <<<"$triage")

  log "прогон завершён"
}

case "${1:-}" in
  render-dates) render_dates ;;
  calendar) main calendar ;;
  tasks) main tasks ;;
  task) run_task "$(realpath "$2")" ;;
  "")   main ;;
  *)    echo "Использование: $0 [task <dir>]" >&2; exit 2 ;;
esac
