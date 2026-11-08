"""Append current calendar deadlines to a morning briefing, without an LLM call."""
from datetime import date, datetime, time
import json
from pathlib import Path
import sys
from zoneinfo import ZoneInfo

MARKER = '**Актуальные дедлайны**'


def render(events, now):
    rows = []
    for event in events:
        if event['kind'] not in ('deadline', 'exam', 'defense') or event['status'] == 'cancelled':
            continue
        day = date.fromisoformat(event['date']) if event['date'] else None
        if day and day < now.date():
            continue
        if day == now.date() and event['time']:
            due = datetime.combine(day, time.fromisoformat(event['time']), tzinfo=now.tzinfo)
            if due < now:
                continue
        label = day.strftime('%d.%m.%Y') if day else 'Дата не указана'
        if event['time']: label += ', ' + event['time'] + ' МСК'
        mark = {'tentative': ' (предварительно)', 'moved': ' (перенесено)'}.get(event['status'], '')
        action = f"{event['course']}: {event['title']}"
        rows.append((event['date'] or '9999-99-99', event['time'] or '23:59',
                     f'• {label} — {action}{mark}'))
    rows.sort()
    lines = list(dict.fromkeys(row[2] for row in rows))
    return '**Актуальные дедлайны**\n\n' + ('\n'.join(lines) if lines else 'Нет известных актуальных дедлайнов.')


def append(summary, calendar):
    data = json.loads(calendar.read_text(encoding='utf-8'))
    base = summary.read_text(encoding='utf-8').split(MARKER, 1)[0].rstrip()
    text = base + '\n\n' + render(data['events'], datetime.now(ZoneInfo('Europe/Moscow'))) + '\n'
    temporary = summary.with_suffix('.md.tmp')
    temporary.write_text(text, encoding='utf-8')
    temporary.replace(summary)


if __name__ == '__main__':
    append(Path(sys.argv[1]), Path(sys.argv[2]))
