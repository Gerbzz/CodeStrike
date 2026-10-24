"""Compare stock analyzer diagnostic delivery with compiler checking off/on.

Research fixture: separate from native GUI acceptance, never a substitute for it.
"""
from datetime import datetime, timezone
import argparse
import json
from pathlib import Path
import tempfile
from lsp_fixture import Client, INVALID, fixture, options, write_frame

class ConfiguredClient(Client):
    def __init__(self, binary, root, config):
        self.config = config
        super().__init__(binary, root)
    def _handle(self, message):
        if message.get('method') == 'textDocument/publishDiagnostics':
            print(json.dumps({'received_utc': datetime.now(timezone.utc).isoformat(), 'diagnostic_response': message.get('params')}), flush=True)
        if message.get('method') == 'workspace/configuration' and 'id' in message:
            values = []
            for item in message.get('params', {}).get('items', []):
                section = item.get('section', 'rust-analyzer')
                value = self.config
                if section != 'rust-analyzer':
                    for part in section.removeprefix('rust-analyzer.').split('.'):
                        value = value.get(part) if isinstance(value, dict) else None
                values.append(value)
            write_frame(self.process.stdin, {'jsonrpc':'2.0','id':message['id'],'result':values})
            return
        super()._handle(message)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args = parser.parse_args()
    results = []
    for enabled in (False, True):
        with tempfile.TemporaryDirectory(prefix='codestrike-stock-diagnostics-') as temporary:
            root, source, _ = fixture(temporary)
            # Windows temp paths may use 8.3 names; compare the canonical file URI.
            root, source = root.resolve(), source.resolve()
            print(json.dumps({'expected_uri': source.as_uri()}), flush=True)
            config = options(enabled)
            print(json.dumps({'started_utc': datetime.now(timezone.utc).isoformat(), 'configuration': config}), flush=True)
            client = ConfiguredClient(args.binary, root, config)
            try:
                client.initialize(config, [(source, INVALID)])
                client.notify('textDocument/didSave', {'textDocument':{'uri':source.as_uri()}})
                def has_error():
                    return any(str(d.get('code')) == 'E0308' for report in client.reports(source.as_uri()) for d in report['diagnostics'])
                try:
                    client.wait(has_error, 45, 'E0308 publication')
                except TimeoutError:
                    pass
                reports = client.reports(source.as_uri())
                result = {'checkOnSave':enabled,'E0308':has_error(),
                          'codes':sorted({str(d.get('code')) for report in reports for d in report['diagnostics']}),
                          'sources':sorted({str(d.get('source')) for report in reports for d in report['diagnostics']}),
                          'fixture_unchanged':source.read_bytes()==INVALID.encode()}
                print(json.dumps(result), flush=True)
                results.append(result)
                evidence = Path('artifacts/stock-diagnostics.json')
                evidence.parent.mkdir(parents=True, exist_ok=True)
                evidence.write_text(json.dumps(results, indent=2), encoding='utf-8')
                assert result['fixture_unchanged']
            finally:
                client.close()
    if not results[1]['E0308']:
        raise AssertionError('Stock analyzer did not deliver required E0308 with compiler checking enabled')
if __name__ == '__main__': main()
