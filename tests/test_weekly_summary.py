import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from datetime import datetime
from unittest.mock import AsyncMock, Mock, patch
from zoneinfo import ZoneInfo

import weekly_summary as weekly


class WeeklyTests(unittest.TestCase):
    def test_calendar_week_at_year_boundary(self):
        now = datetime(2027, 1, 3, 20, tzinfo=ZoneInfo('Europe/Moscow'))
        start, following, end = weekly.periods(now)
        self.assertEqual([x.strftime('%Y-%m-%d %H:%M') for x in (start, following, end)],
                         ['2026-12-28 00:00', '2027-01-04 00:00', '2027-01-11 00:00'])

    def test_chunks_and_empty_sections(self):
        dates = weekly.periods(datetime.now(ZoneInfo('Europe/Moscow')))
        result = {'past_deadlines': ['я' * 1500] * 9, 'next_week_tasks': []}
        chunks = list(weekly.messages(weekly.validate(result), *dates))
        self.assertTrue(all(len(c) <= 3900 for c in chunks))
        self.assertEqual(sum(c.count('я') for c in chunks), 13500)
        self.assertIn('ничего не найдено', chunks[-1])
        with self.assertRaises(ValueError):
            weekly.validate({'past_deadlines': 'invalid', 'next_week_tasks': []})

    def test_send_retry_and_deduplication(self):
        export = AsyncMock(return_value={'chats': []})
        send = Mock(side_effect=RuntimeError('network failure'))
        result = {'past_deadlines': [], 'next_week_tasks': ['Сдать эссе']}
        modules = {'telegram_messages_parser': types.SimpleNamespace(export_folder=export),
                   'send_summary': types.SimpleNamespace(send=send)}
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as tmp, patch.dict(sys.modules, modules), \
                patch.object(weekly, 'request_json', return_value=result), \
                patch.object(sys, 'argv', ['weekly_summary.py']):
            try:
                os.chdir(tmp)
                with self.assertRaises(RuntimeError):
                    weekly.main()
                self.assertFalse(list(Path('state/weekly').glob('*.json')))
                send.side_effect = None
                weekly.main()
                self.assertEqual(send.call_count, 3)
                weekly.main()
                self.assertEqual(send.call_count, 3)
                self.assertEqual(export.await_count, 2)
            finally:
                os.chdir(previous)

    def test_schedule_skips_wrong_time_without_reading(self):
        with patch.object(sys, 'argv', ['weekly_summary.py', '--scheduled']), \
                patch.object(weekly, 'datetime') as clock, \
                patch.object(weekly, 'saved_context') as context:
            clock.now.return_value = datetime(2026, 11, 9, 20, tzinfo=ZoneInfo('Europe/Moscow'))
            weekly.main()
            context.assert_not_called()


if __name__ == '__main__':
    unittest.main()
