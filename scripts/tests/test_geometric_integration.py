"""Preserve the reviewed donor identity and apply it to every supported build route."""
import hashlib
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class GeometricIntegration(unittest.TestCase):
    def test_exact_existing_assets_are_reused(self):
        hashes = {
            'png': 'bc52e0a0ff2ee6553f6d8bf9c91e92d044cf742532db8611320ecd0a621a1c80',
            'svg': '27e871c8413625fcbe85897c3a2708b8f0c1ba8b35ec0b24c9e149b48109a384',
            'ico': '8a4d0e28a801bcf6c552d739ee0c67aec99de5e3265e8aa2a51829d4d3f84d79',
        }
        for extension, expected in hashes.items():
            asset = ROOT / f'assets/branding/CodeStrike-geometric.{extension}'
            self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(), expected)
    def test_overlay_routes_splash_about_and_native_window(self):
        patch = (ROOT / 'editor/patches/codestrike-geometric-overlay.patch').read_text()
        self.assertEqual(patch.count('+                    "../../../../assets/branding/CodeStrike-geometric.png"'), 2)
        self.assertIn('+            if let Ok(icon) = Icon::from_resource(1, None)', patch)
        self.assertIn('windows_icon::embed("../../assets/branding/CodeStrike-geometric.ico", "lapce")', patch)
        self.assertFalse((ROOT / 'src/bin/desktop.rs').exists())
    def test_build_routes_apply_post_donor_branding(self):
        self.assertIn('prepare-lapce-branding.ps1', (ROOT / 'scripts/build-codestrike.ps1').read_text())
        for name in ['editor-candidate', 'rust-language-tools', 'reviewed-rust-analyzer', 'geometric-branding']:
            text = (ROOT / f'.github/workflows/{name}.yml').read_text()
            self.assertIn('prepare-lapce-branding.ps1', text)
        self.assertIn('assets/branding/CodeStrike-geometric.svg', (ROOT / 'README.md').read_text())

if __name__ == '__main__':
    unittest.main()
