"""Guard probe ordering/evidence; real acceptance remains the three native runs."""
from pathlib import Path
import os
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ReadinessContract(unittest.TestCase):
    def test_enter_requires_fresh_laid_out_selected_row(self):
        script = Path(os.environ.get('CODESTRIKE_READINESS_PROBE', ROOT / 'scripts/probe-rust-language-tools.ps1')).read_text()
        boundary = script.index('$completionOutputStart =')
        request = script.index("SendWait('^i')", boundary)
        readiness = script.index("Wait-LspOutput 'CodeStrike completion row laid out' 'selected_label=\"Read\"' 60 $completionOutputStart", request)
        enter = script.index("SendWait('{ENTER}')", readiness)
        self.assertLess(boundary, request)
        self.assertLess(readiness, enter)
        self.assertNotIn('Start-Sleep -Seconds 8', script)
        self.assertNotIn('Start-Sleep -Seconds 45', script)
        self.assertIn("Wait-LspOutput 'textDocument/publishDiagnostics' 'E0308' 120", script)
    def test_failure_retains_real_trace_and_exact_source(self):
        script = Path(os.environ.get('CODESTRIKE_READINESS_PROBE', ROOT / 'scripts/probe-rust-language-tools.ps1')).read_text()
        finalizer = script[script.index('} finally {\n    $cleanupFailures'):]
        for filename in ['failure.png', 'synthetic-fixture-lsp.log', 'saved-source.rs']:
            self.assertIn(filename, finalizer)
        self.assertIn("[IO.File]::ReadAllBytes($source)", finalizer)
        self.assertIn('} catch {\n    $probeFailure = $_\n    throw', script)
        self.assertIn('Complete-LspCleanup $probeFailure $cleanupFailures', finalizer)
        for name in ['close native process', 'terminate remaining native process', 'drain console capture', 'retain raw trace', 'retain saved source', 'dispose process']:
            self.assertIn(f"Invoke-LspCleanupStep '{name}'", finalizer)
        self.assertIn('Completion selection did not save the expected UTF-8 bytes', script)
        self.assertIn("Contains('E0308')", script)
    def test_observation_overlay_and_native_tests_remain_wired(self):
        prep = (ROOT / 'scripts/prepare-lapce-language.ps1').read_text()
        self.assertIn('codestrike-save-capability.patch', prep)
        self.assertIn('codestrike-completion-observation.patch', prep)
        workflow = (ROOT / '.github/workflows/rust-language-tools.yml').read_text()
        self.assertIn('-p lapce-app completion_observation_tests --lib', workflow)
        self.assertIn('test-lsp-readiness.ps1', workflow)
        self.assertNotIn('continue-on-error', workflow)
        for index in range(1, 4):
            self.assertEqual(workflow.count(f"-EvidenceDirectory 'artifacts/lsp-native/attempt-{index}'"), 1)

if __name__ == '__main__':
    unittest.main()
