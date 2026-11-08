from datetime import datetime
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo
import morning_deadlines as m


class MorningTests(unittest.TestCase):
    def test_filters_and_sorting(self):
        def event(day, status='active', kind='deadline', at=None):
            return dict(date=day, time=at, status=status, kind=kind, course='Курс', title='Сдать ДЗ')
        now = datetime(2026,11,8,8,tzinfo=ZoneInfo('Europe/Moscow'))
        text=m.render([event('2026-11-07'), event('2026-11-08',at='07:00'),
            event('2026-11-09','cancelled'), event('2026-11-10',kind='schedule_change'),
            event(None), event('2026-11-12','tentative'), event('2026-11-09','moved')],now)
        self.assertNotIn('07.11',text)
        self.assertNotIn('07:00',text)
        self.assertNotIn('10.11',text)
        self.assertLess(text.index('09.11'),text.index('12.11'))
        self.assertLess(text.index('12.11'),text.index('Дата не указана'))
        self.assertIn('предварительно',text)
        self.assertIn('перенесено',text)

    def test_idempotent_append(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary=Path(tmp)/'summary.md'; calendar=Path(tmp)/'dates.json'
            summary.write_text('Утренняя сводка')
            calendar.write_text('{"events": []}')
            m.append(summary,calendar); m.append(summary,calendar)
            text=summary.read_text()
            self.assertEqual(text.count('Актуальные дедлайны'),1)
            self.assertTrue(text.startswith('Утренняя сводка'))
