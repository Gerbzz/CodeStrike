from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class SaveReadbackContract(unittest.TestCase):
    def test_one_native_save_then_same_predicate_and_retained_failure(self):
        probe = (ROOT / 'scripts/probe-windows-editor.ps1').read_text()
        self.assertEqual(probe.count("SendWait('^s')"), 1)
        self.assertEqual(probe.count("SendWait('codestrike_ci_saved')"), 1)
        self.assertLess(probe.index("SendWait('^s')"), probe.index('$saveObservation = Wait-EditorSavedSource'))
        self.assertIn("$fileSavePassed = $savedSource.Contains('codestrike_ci_saved')", probe)
        self.assertIn("throw 'Keyboard edit/save did not reach the opened fixture file.'", probe)
        self.assertLess(probe.index('[IO.File]::WriteAllBytes'), probe.index("throw 'Keyboard edit/save"))
    def test_read_only_bounded_observation_and_hosted_regressions(self):
        helper = (ROOT / 'scripts/wait-editor-save.ps1').read_text()
        self.assertIn('$TimeoutMilliseconds = 10000', helper)
        self.assertIn('$elapsed.ElapsedMilliseconds -ge $TimeoutMilliseconds', helper)
        for forbidden in ['SendWait', 'SendKeys', 'WriteAll', 'Set-Content']:
            self.assertNotIn(forbidden, helper)
        workflow = (ROOT / '.github/workflows/lapce-cutover-contracts.yml').read_text()
        self.assertIn('test-editor-save-readback.ps1', workflow)
        self.assertNotIn('continue-on-error', workflow)

if __name__ == '__main__':
    unittest.main()
