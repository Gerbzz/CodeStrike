"""Regression contracts for the Lapce-only product route and preserved donors."""
import hashlib
from pathlib import Path
import subprocess
import tomllib
import unittest
ROOT = Path(__file__).resolve().parents[2]
class LapceCutover(unittest.TestCase):
    def test_no_pre_lapce_desktop_target(self):
        manifest = tomllib.loads((ROOT / 'Cargo.toml').read_text())
        self.assertFalse((ROOT / 'src/bin/desktop.rs').exists())
        self.assertFalse({'eframe', 'rfd', 'png'} & manifest['dependencies'].keys())
        self.assertEqual(manifest['package']['default-run'], 'codestrike')
        self.assertTrue(manifest['package']['autobins'] is False)
    def test_default_is_lapce_launcher(self):
        source = (ROOT / 'src/main.rs').read_text()
        self.assertIn('CODESTRIKE_EDITOR', source)
        self.assertIn('editor/lapce/target', source)
        self.assertNotIn('Document::open', source)
        self.assertNotIn('codestrike-desktop', (ROOT / 'README.md').read_text())
    def test_preserved_sources_are_byte_identical(self):
        for name in ['src/lib.rs', 'src/process_scope.rs', 'editor/patches/codestrike-lapce.patch',
                     'scripts/prepare-lapce.ps1', 'third_party/rust-analyzer/reviewed-v12.patch']:
            old = subprocess.check_output(['git', 'show', '6d97fe3bca09793ba49dbd848365a2a98f5098c1:' + name], cwd=ROOT)
            self.assertEqual((ROOT / name).read_bytes(), old, name)
        pin = subprocess.check_output(['git', 'ls-files', '--stage', 'editor/lapce'], cwd=ROOT).decode()
        self.assertIn('b012cef466741528f338879fa708355217fc40bd', pin)
    def test_legacy_cli_is_named_tool_not_default_editor(self):
        manifest = tomllib.loads((ROOT / 'Cargo.toml').read_text())
        self.assertIn({'name': 'codestrike-core-tool', 'path': 'tools/core-cli.rs'}, manifest['bin'])
        self.assertEqual((ROOT / 'tools/core-cli.rs').read_bytes(), subprocess.check_output(
            ['git', 'show', '6d97fe3bca09793ba49dbd848365a2a98f5098c1:src/main.rs'], cwd=ROOT))
if __name__ == '__main__': unittest.main()
