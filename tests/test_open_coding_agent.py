import os, subprocess, tempfile, unittest
from pathlib import Path
HOOK=Path(os.environ.get('OPEN_CODING_AGENT_HOOK', Path(__file__).resolve().parents[1] / 'dotfiles' / '.hooks' / 'open_coding_agent'))
URL='https://bitbucket.org/cetarktech/genai-bi/pull-requests/130'
class HookTest(unittest.TestCase):
    def run_hook(self,url=URL,queue_status=0,open_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); log=root/'calls'
            for name in ('codex','open','python3'):
                script=root/name
                script.write_text('#!/bin/sh\n'+
                    'printf "%s\\n" "'+name+' $*" >> "$CALL_LOG"\n'+
                    ('exit "$QUEUE_STATUS"\n' if name=='codex' else 'exit "$OPEN_STATUS"\n' if name=='open' else 'exit 99\n'))
                script.chmod(0o755)
            env=dict(os.environ,PATH=f'{root}:/usr/bin:/bin',CALL_LOG=str(log),QUEUE_STATUS=str(queue_status),OPEN_STATUS=str(open_status),PR_MONITOR_PR_URL=url,PR_MONITOR_CODEX_BIN=str(root/'codex'),PR_MONITOR_OPEN_BIN=str(root/'open'),PR_MONITOR_CODEX_DISPATCHER='test-dispatcher')
            result=subprocess.run(['/bin/zsh',str(HOOK)],env=env,text=True,capture_output=True)
            return result, log.read_text() if log.exists() else ''
    def test_desktop_handoff_does_not_claim_writer(self):
        result,calls=self.run_hook()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('codex queue --thread test-dispatcher --message $get-ready '+URL,calls)
        self.assertIn('open codex://threads/test-dispatcher',calls)
        self.assertIn('If a suitable chat exists, open that existing chat',calls)
        self.assertIn('only after confirming no suitable existing chat exists and the branch is free',calls)
        self.assertNotIn('Open this PR in a new Codex Desktop thread',calls)
        self.assertNotIn('python3 ',calls)
        self.assertNotIn('--resume',calls)
        self.assertIn('does not confirm',result.stdout)
    def test_invalid_url_does_nothing(self):
        result,calls=self.run_hook('https://example.com/130')
        self.assertNotEqual(result.returncode,0);self.assertEqual(calls,'')
    def test_queue_failure_does_not_open_or_report_success(self):
        result,calls=self.run_hook(queue_status=42)
        self.assertEqual(result.returncode,42)
        self.assertNotIn('open codex://threads/',calls);self.assertNotIn('queued',result.stdout)
    def test_open_failure_reports_already_queued(self):
        result,calls=self.run_hook(open_status=43)
        self.assertEqual(result.returncode,0)
        self.assertIn('queued',result.stderr)
        self.assertIn('manually',result.stderr)
if __name__=='__main__':unittest.main()
