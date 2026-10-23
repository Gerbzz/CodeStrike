"""Compile the real launcher and a fake editor; exercise argv/exit/fail-closed."""
from pathlib import Path
import os, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[2]
class Launcher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='codestrike launcher ')
        cls.work = Path(cls.temp.name)
        cls.launcher = cls.work / ('launcher.exe' if os.name == 'nt' else 'launcher')
        cls.editor = cls.work / ('editor.exe' if os.name == 'nt' else 'editor')
        env = dict(os.environ, CARGO_MANIFEST_DIR=str(cls.work))
        subprocess.run(['rustc', '--edition=2024', str(ROOT/'src/main.rs'), '-o', str(cls.launcher)], env=env, check=True)
        fixture = cls.work/'fixture.rs'
        fixture.write_text('fn main() { for a in std::env::args().skip(1) { println!("{a}"); } std::process::exit(7); }')
        subprocess.run(['rustc', str(fixture), '-o', str(cls.editor)], check=True)
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def test_exact_argument_and_status_forwarding(self):
        args=['folder with spaces', 'semi;colon', '$(not-a-command)', 'café']
        p=subprocess.run([str(self.launcher),*args],env=dict(os.environ,CODESTRIKE_EDITOR=str(self.editor)),text=True,capture_output=True)
        self.assertEqual(p.returncode,7); self.assertEqual(p.stdout.splitlines(),args)
    def test_missing_editor_fails_without_fallback(self):
        env=dict(os.environ); env.pop('CODESTRIKE_EDITOR',None)
        p=subprocess.run([str(self.launcher)],env=env,text=True,capture_output=True)
        self.assertNotEqual(p.returncode,0); self.assertIn('scripts/build-codestrike.ps1',p.stderr)
if __name__=='__main__': unittest.main()
