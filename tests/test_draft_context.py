"""Exercise real task control flow with mocked LLM responses, no network."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFINITIONS = (ROOT / 'act.sh').read_text().rsplit('\ncase "${1:-}" in', 1)[0]
MOCKS = r'''
PROVIDER=codex
REVIEWER2=codex
MAX_ROUNDS=1
log() { :; }
check_injection() { return 0; }
ask() {
  cat >/dev/null
  if [ "$1" = context_check ]; then
    printf '%s\n' "$TEST_CONTEXT_RESPONSE"
  else
    printf '%s\n' '{"verdict":"ok","issues":[]}'
  fi
}
codex_draft() {
  touch executor_called
  printf 'Содержательный черновик\n' > draft.md
  printf '{"is_error":false}\n' > "$2"
}
'''


class DraftContextTests(unittest.TestCase):
    def run_task(self, response):
        with tempfile.TemporaryDirectory() as tmp:
            task = Path(tmp)
            (task/'task.json').write_text(json.dumps({'title':'ДЗ','type':'document'}))
            (task/'dates.md').write_text('Календарь')
            # Avoid reading real messages in the test.
            script = DEFINITIONS + '\n' + MOCKS + '\nbundle_messages() { echo "Условие в edu"; }\nrun_task "$1"\n'
            env = dict(os.environ, TEST_CONTEXT_RESPONSE=response)
            result = subprocess.run(['bash','-c',script,str(ROOT/'act.sh'),tmp],
                                    text=True,capture_output=True,env=env)
            outcome=json.loads((task/'result.json').read_text()) if (task/'result.json').exists() else None
            return result, outcome, (task/'executor_called').exists(), (task/'draft.md').exists()

    def test_missing_external_assignment_skips_executor(self):
        result, outcome, called, draft = self.run_task(json.dumps({
            'sufficient':False,'reason':'Нет условия из edu','missing':['Текст задания']}))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(outcome['status'],'insufficient_context')
        self.assertEqual(outcome['missing'],['Текст задания'])
        self.assertFalse(called)
        self.assertFalse(draft)

    def test_available_assignment_continues_to_review(self):
        result, outcome, called, draft = self.run_task(json.dumps({
            'sufficient':True,'reason':'Условие приведено в сообщении','missing':[]}))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(outcome['status'],'ok')
        self.assertTrue(called)
        self.assertTrue(draft)

    def test_malformed_verdict_never_starts_executor(self):
        for response in ['{}','{"sufficient":"false","reason":"нет","missing":[]}',
                         '{"sufficient":true,"reason":"ok","missing":[1]}']:
            with self.subTest(response=response):
                result, outcome, called, draft = self.run_task(response)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(called)
                self.assertFalse(draft)
