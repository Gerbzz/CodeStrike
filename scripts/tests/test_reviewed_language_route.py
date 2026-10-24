"""Contracts for the explicit source-built server route, not runtime acceptance."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ReviewedLanguageRoute(unittest.TestCase):
    def test_build_reuses_reviewed_guards_without_hooks(self):
        script = (ROOT / 'scripts/analyzer/build-reviewed-analyzer.ps1').read_text()
        self.assertIn("prepare-reviewed-source.ps1", script)
        self.assertIn("rust-toolchain-guard.ps1", script)
        self.assertIn("8bab26f4f68e0e26f0bb7960be334d5b520ea452", script)
        self.assertIn("-p rust-analyzer --lib", script)
        self.assertNotIn("WithTestHooks", script)
    def test_probe_requires_selected_binary_and_real_workspace_setting(self):
        script = (ROOT / 'scripts/probe-rust-language-tools.ps1').read_text()
        self.assertIn('[Parameter(Mandatory = $true)][string]$AnalyzerPath', script)
        self.assertIn('serverPath = $analyzerToml', script)
        self.assertIn('CODESTRIKE_LSP_ANALYZER_SHA256=', script)
        self.assertIn("Contains('E0308')", script)
        self.assertIn('Completion selection did not save the expected UTF-8 bytes', script)
    def test_all_three_native_attempts_are_required_and_isolated(self):
        workflow = (ROOT / '.github/workflows/rust-language-tools.yml').read_text()
        self.assertIn('build-reviewed-analyzer.ps1', workflow)
        self.assertNotIn('continue-on-error', workflow)
        for index in range(1, 4):
            self.assertEqual(workflow.count(f"-EvidenceDirectory 'artifacts/lsp-native/attempt-{index}'"), 1)
        self.assertEqual(workflow.count("-AnalyzerPath (Join-Path $env:RUNNER_TEMP 'reviewed-analyzer-target/debug/rust-analyzer.exe')"), 3)

if __name__ == '__main__':
    unittest.main()
