"""Bounded direct-LSP replay of native a771 diagnostic sequence, not GUI acceptance."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile
from lsp_fixture import Client

# Exact native initialize capabilities captured from the synthetic a771 fixture.
CAPABILITIES = {'experimental': {'commands': {'commands': ['rust-analyzer.runSingle', 'rust-analyzer.debugSingle']}, 'serverStatusNotification': True}, 'textDocument': {'callHierarchy': {'dynamicRegistration': True}, 'codeAction': {'codeActionLiteralSupport': {'codeActionKind': {'valueSet': ['', 'quickfix', 'refactor', 'refactor.extract', 'refactor.inline', 'refactor.rewrite', 'source', 'source.organizeImports', 'quickassist', 'source.fixAll']}}, 'dataSupport': True, 'resolveSupport': {'properties': ['edit']}}, 'completion': {'completionItem': {'resolveSupport': {'properties': ['additionalTextEdits']}, 'snippetSupport': True}}, 'definition': {}, 'documentSymbol': {'hierarchicalDocumentSymbolSupport': True}, 'foldingRange': {'dynamicRegistration': False, 'lineFoldingOnly': False}, 'hover': {'contentFormat': ['markdown', 'plaintext']}, 'inlayHint': {}, 'inlineCompletion': {}, 'publishDiagnostics': {}, 'semanticTokens': {'formats': [], 'requests': {}, 'tokenModifiers': [], 'tokenTypes': []}, 'signatureHelp': {'signatureInformation': {'activeParameterSupport': True, 'documentationFormat': ['markdown', 'plaintext'], 'parameterInformation': {'labelOffsetSupport': True}}}, 'synchronization': {'didSave': True, 'dynamicRegistration': True}, 'typeDefinition': {'linkSupport': False}}, 'window': {'showMessage': {'messageActionItem': {'additionalPropertiesSupport': True}}, 'workDoneProgress': True}, 'workspace': {'configuration': False, 'symbol': {}, 'workspaceFolders': True}}
INITIAL = 'use std::io::Re;\nfn main() { let value: i32 = "wrong"; println!("{value}"); }'
EXPECTED = INITIAL.replace('::Re;', '::Read;')
CONFIG = {"checkOnSave": False, "serverPath": "rust-analyzer"}

def emit(value):
    print(json.dumps({"utc": datetime.now(timezone.utc).isoformat(), **value}), flush=True)

class ReplayClient(Client):
    def _handle(self, message):
        if message.get('method') in ('textDocument/publishDiagnostics', 'experimental/serverStatus', 'client/registerCapability', 'window/logMessage', 'window/showMessage'):
            emit({"server_message": message})
        super()._handle(message)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args = parser.parse_args()
    results = []
    for send_save in (False, True):
        with tempfile.TemporaryDirectory(prefix='codestrike-gui-replay-') as temporary:
            root = (Path(temporary) / 'fixture')
            (root / 'src').mkdir(parents=True)
            root = root.resolve()
            source = root / 'src/main.rs'
            source.write_bytes(INITIAL.encode())
            (root / 'Cargo.toml').write_bytes(b'[package]\nname = "codestrike_lsp_fixture"\nversion = "0.1.0"\nedition = "2021"')
            client = ReplayClient(args.binary, root)
            try:
                uri = source.as_uri()
                params = {"processId":os.getpid(), "rootUri":root.as_uri()+'/',
                          "workspaceFolders":[{"uri":root.as_uri()+'/',"name":root.as_uri()+'/'}],
                          "capabilities":CAPABILITIES,"initializationOptions":CONFIG,"trace":"verbose"}
                emit({"send_didSave":send_save,"initialize":params,"source_uri":uri})
                client.request('initialize',params,35)
                client.notify('initialized',{})
                client.notify('textDocument/didOpen',{'textDocument':{'uri':uri,'languageId':'rust','version':1,'text':INITIAL}})
                client.hold(45)
                client.edit(source,2,EXPECTED)
                client.hold(0.5)
                client.edit(source,3,EXPECTED)
                if send_save:
                    client.notify('textDocument/didSave',{'textDocument':{'uri':uri}})
                client.hold(30)
                reports=client.reports(uri)
                result={"send_didSave":send_save,"E0308":any(str(d.get('code'))=='E0308' for r in reports for d in r['diagnostics']),
                        "reports":reports,"disk_exact":source.read_bytes()==EXPECTED.encode(),
                        "server_exact":client.request('rust-analyzer/viewFileText',{'uri':uri},12)==EXPECTED,
                        "stderr_tail":client.stderr_tail.decode(errors='replace')}
                emit(result)
                assert result['disk_exact'] and result['server_exact'], 'Replay source diverged'
                results.append(result)
            finally:
                client.close()
    output=Path('artifacts/gui-diagnostic-replay.json')
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(results,indent=2))
if __name__ == '__main__': main()
