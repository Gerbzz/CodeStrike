"""Fixture-only probe for the pinned rust-analyzer semantic scheduling guard.

The instrument subcommand modifies only a disposable checkout of official Rust.
The compare subcommand imports CodeStrike's existing standalone probe unchanged.
"""

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time


PINNED_COMMIT = "b940084d7eb6a299eb4bfeb8e34901bc051e7ac4"
GUARD_SOURCE = Path("src/tools/rust-analyzer/crates/rust-analyzer/src/main_loop.rs")
ORIGINAL = """                let fetch_semantic = self.vfs_done
                    && self.fetch_workspaces_queue.last_op_result().is_some()
                    && (!self.config.run_build_scripts(None)
                        || (self.fetch_build_data_queue.last_op_result().is_none()
                            && !self.fetch_build_data_queue.op_in_progress()))
                    && (!self.config.expand_proc_macros()
                        || (self.fetch_proc_macros_queue.last_op_result().is_none()
                            && !self.fetch_proc_macros_queue.op_in_progress()));"""
INSTRUMENTED = """                let guard_vfs_done = self.vfs_done;
                let guard_document_version = subscriptions.first()
                    .and_then(|file_id| self.file_version(*file_id)).unwrap_or(-1);
                let guard_workspace_ready = self.fetch_workspaces_queue.last_op_result().is_some();
                let guard_build_enabled = self.config.run_build_scripts(None);
                let guard_build_last_none = self.fetch_build_data_queue.last_op_result().is_none();
                let guard_build_in_progress = self.fetch_build_data_queue.op_in_progress();
                let guard_proc_enabled = self.config.expand_proc_macros();
                let guard_proc_last_none = self.fetch_proc_macros_queue.last_op_result().is_none();
                let guard_proc_in_progress = self.fetch_proc_macros_queue.op_in_progress();
                let original_fetch_semantic = guard_vfs_done
                    && guard_workspace_ready
                    && (!guard_build_enabled || (guard_build_last_none && !guard_build_in_progress))
                    && (!guard_proc_enabled || (guard_proc_last_none && !guard_proc_in_progress));
                let experiment_requested = std::env::var_os("CODESTRIKE_RA_GUARD_FLAG")
                    .is_some_and(|path| std::path::Path::new(&path).is_file());
                let experiment_ready = guard_vfs_done && guard_workspace_ready
                    && !guard_build_in_progress && !guard_proc_in_progress;
                let fetch_semantic = original_fetch_semantic
                    || (experiment_requested && experiment_ready);
                tracing::warn!(
                    "CODESTRIKE_GUARD generation={:?} document_version={} vfs_done={} workspace_ready={} build_enabled={} build_last_none={} build_in_progress={} proc_enabled={} proc_last_none={} proc_in_progress={} original_fetch_semantic={} experiment_requested={} fetch_semantic={}",
                    generation, guard_document_version,
                    guard_vfs_done, guard_workspace_ready, guard_build_enabled, guard_build_last_none,
                    guard_build_in_progress, guard_proc_enabled, guard_proc_last_none,
                    guard_proc_in_progress, original_fetch_semantic,
                    experiment_requested, fetch_semantic
                );"""
FIELDS = (
    "vfs_done", "workspace_ready", "build_enabled", "build_last_none",
    "build_in_progress", "proc_enabled", "proc_last_none", "proc_in_progress",
    "original_fetch_semantic", "experiment_requested", "fetch_semantic",
)
MARKER = re.compile(r"CODESTRIKE_GUARD generation=(\d+) document_version=(-?\d+)\s+((?:[a-z_]+=(?:true|false)\s*){11})")


def patch_source(source):
    if source.count(ORIGINAL) != 1:
        raise RuntimeError("Pinned semantic guard differs from the reviewed source")
    return source.replace(ORIGINAL, INSTRUMENTED, 1)


def classify_guard(line):
    match = MARKER.search(line)
    if not match:
        return None
    parts = dict(re.findall(r"([a-z_]+)=(true|false)", match.group(3)))
    if set(parts) != set(FIELDS):
        raise RuntimeError("Incomplete semantic guard marker")
    event = {key: parts[key] == "true" for key in FIELDS}
    event["kind"] = "guard"
    event["generation"] = int(match.group(1))
    event["document_version"] = int(match.group(2))
    # Detect accidental drift in the rewritten but equivalent predicate.
    expected = (event["vfs_done"] and event["workspace_ready"]
                and (not event["build_enabled"] or
                     (event["build_last_none"] and not event["build_in_progress"]))
                and (not event["proc_enabled"] or
                     (event["proc_last_none"] and not event["proc_in_progress"])))
    if event["original_fetch_semantic"] != expected:
        raise RuntimeError("Instrumented predicate differs from the pinned guard")
    actual = expected or (event["experiment_requested"] and event["vfs_done"]
                          and event["workspace_ready"] and not event["build_in_progress"]
                          and not event["proc_in_progress"])
    if event["fetch_semantic"] != actual:
        raise RuntimeError("Instrumented decision differs from the reviewed experiment")
    return event


def instrument(checkout):
    source_path = checkout / GUARD_SOURCE
    before = source_path.read_text(encoding="utf-8")
    after = patch_source(before)
    source_path.write_text(after, encoding="utf-8", newline="\n")
    print("CODESTRIKE_GUARD_SOURCE_PATCH=single reviewed guard;predicate-equivalent;logging-only", flush=True)


def load_probe(path):
    spec = importlib.util.spec_from_file_location("codestrike_standalone_probe", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    prior_classifier = module.classify_main_loop_line

    def classifier(line):
        event = classify_guard(line) or prior_classifier(line)
        if event is not None and event["kind"] in ("syntax_result", "semantic_result"):
            match = re.search(r"Diagnostics\((?:Syntax|Semantic)\((\d+)", line)
            if match:
                event["generation"] = int(match.group(1))
        return event

    module.classify_main_loop_line = classifier
    return module


def has_progress_end(client, suffix):
    return any(item["kind"] == "end" and item["token"].endswith(suffix)
               for item in client.progress)


def read_server_text(module, client, uri, request_id, expected, source):
    client.send("rust-analyzer/viewFileText", {"uri": uri}, request_id=request_id)
    reply = client.wait_for(lambda msg: module.is_reply(msg, request_id), uri, 8,
                            "exact server text response")
    return (reply.get("result") == expected and
            reply.get("result", "").encode("utf-8") == source.read_bytes())


def run_case(module, binary, case, base, flag_path, experimental):
    root, source = module.make_fixture(base)
    uri = source.as_uri()
    root_uri = root.as_uri() + "/"
    original_env = os.environ.get("CODESTRIKE_RA_GUARD_FLAG")
    os.environ["CODESTRIKE_RA_GUARD_FLAG"] = str(flag_path)
    try:
        client = module.Client([str(binary)], root, time.monotonic() + 165, case,
                               trace_main_loop=True)
    finally:
        if original_env is None:
            del os.environ["CODESTRIKE_RA_GUARD_FLAG"]
        else:
            os.environ["CODESTRIKE_RA_GUARD_FLAG"] = original_env
    barrier = None
    text_matches = {}
    pulled_e0308 = None
    sent = []
    try:
        client.send("initialize", {
            "processId": os.getpid(),
            "clientInfo": {"name": "CodeStrike guard diagnostic", "version": "1"},
            "rootUri": root_uri,
            "rootPath": str(root),
            "workspaceFolders": [{"uri": root_uri, "name": root.name}],
            "capabilities": {
                "workspace": {"workspaceFolders": True, "configuration": True},
                "textDocument": {"synchronization": {"dynamicRegistration": False},
                                 "publishDiagnostics": {"versionSupport": True}},
                "window": {"workDoneProgress": True},
                "experimental": {"serverStatusNotification": True},
            },
            "initializationOptions": module.DEFAULT_OPTIONS,
        }, request_id=1)
        reply = client.wait_for(lambda msg: module.is_reply(msg, 1), uri, 35,
                                "initialize response")
        if "error" in reply:
            raise RuntimeError("Analyzer rejected initialize: " + str(reply["error"])[:160])
        client.send("initialized", {})
        client.send("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "rust", "version": 1,
                             "text": module.INVALID}
        })
        sent.append({"version": 1, "t_ms": round((time.monotonic() - client.started) * 1000)})

        # The edit barrier depends on workspace, VFS/progress, and build/proc
        # readiness. It never waits for E0308 or any diagnostic publication.
        barrier_deadline = min(client.deadline, time.monotonic() + 80)
        request_id = 20
        while time.monotonic() < barrier_deadline:
            client.send("rust-analyzer/analyzerStatus", {"textDocument": {"uri": uri}},
                        request_id=request_id)
            status_reply = client.wait_for(lambda msg, rid=request_id: module.is_reply(msg, rid),
                                           uri, 8, "workspace readiness")
            status = module.summarize_analyzer_status(status_reply.get("result"), root)
            quiescent = bool(client.server_status and
                             client.server_status[-1].get("quiescent") is True)
            build_done = has_progress_end(client, "Building compile-time-deps")
            proc_done = has_progress_end(client, "Loading proc-macros")
            if status.get("loaded") and status.get("workspace_root_mentions_fixture") \
                    and quiescent and build_done and proc_done:
                barrier = {"loaded": status["loaded"], "quiescent": quiescent,
                           "build_done": build_done, "proc_done": proc_done,
                           "t_ms": round((time.monotonic() - client.started) * 1000)}
                break
            request_id += 1
            time.sleep(0.25)
        if barrier is None:
            raise RuntimeError(case + " did not reach the common readiness barrier")
        if experimental:
            flag_path.write_text("fixture-only diagnostic override\n", encoding="utf-8")

        source.write_bytes(module.VALID.encode("utf-8"))
        client.send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 2},
            "contentChanges": [{"text": module.VALID}],
        })
        sent.append({"version": 2, "t_ms": round((time.monotonic() - client.started) * 1000)})
        text_matches["v2"] = read_server_text(module, client, uri, 5, module.VALID, source)
        time.sleep(1)
        source.write_bytes(module.DISTINCT_INVALID.encode("utf-8"))
        client.send("textDocument/didChange", {
            "textDocument": {"uri": uri, "version": 3},
            "contentChanges": [{"text": module.DISTINCT_INVALID}],
        })
        sent.append({"version": 3, "t_ms": round((time.monotonic() - client.started) * 1000)})
        text_matches["v3"] = read_server_text(module, client, uri, 6,
                                               module.DISTINCT_INVALID, source)
        if not all(text_matches.values()):
            raise RuntimeError(case + " server text failed exact disk and source comparison")
        if not any(item["version"] == 3 and "E0308" in item["codes"]
                   for item in client.diagnostics):
            try:
                client.wait_for(lambda msg: module.diag_at(msg, uri, 3, True), uri, 35,
                                "passive restored-v3 E0308")
            except TimeoutError:
                pass
        client.send("textDocument/diagnostic", {"textDocument": {"uri": uri}}, request_id=7)
        pull_reply = client.wait_for(lambda msg: module.is_reply(msg, 7), uri, 10,
                                     "auxiliary pull diagnostic")
        pulled_e0308 = any(item.get("code") == "E0308"
                             for item in pull_reply.get("result", {}).get("items", []))
    finally:
        client.close(uri)
    events = client.main_loop_events
    guard = [event for event in events if event.get("kind") == "guard"]
    if not guard:
        raise RuntimeError(case + " did not report any resolved guard state")
    return {
        "case": case,
        "barrier": barrier,
        "sent": sent,
        "text_matches": text_matches,
        "push_v3_e0308": any(item["version"] == 3 and "E0308" in item["codes"]
                              for item in client.diagnostics),
        "pull_v3_e0308": pulled_e0308,
        "diagnostics": [{"t_ms": item["t_ms"], "version": item["version"],
                         "codes": item["codes"]} for item in client.diagnostics[-10:]],
        "events": [{key: value for key, value in item.items() if key != "subscriptions"}
                   for item in events[-65:]],
    }


def compare(probe_path, instrumented_binary):
    module = load_probe(probe_path)
    if not instrumented_binary.is_file():
        raise RuntimeError("Instrumented analyzer binary unavailable")
    version = module.analyzer_version(str(instrumented_binary), None)
    if not version.startswith("rust-analyzer 1.99.0 (b940084d "):
        raise RuntimeError("Built analyzer version differs from the pinned release: " + version)
    print("CODESTRIKE_GUARD_EXPERIMENT_ANALYZER=" + version, flush=True)
    with tempfile.TemporaryDirectory(prefix="codestrike-ra-guard-",
                                     dir=os.environ.get("RUNNER_TEMP")) as scratch:
        scratch = Path(scratch)
        flag_path = scratch / "diagnostic-override.flag"
        results = []
        for case, enabled in (("instrumented_baseline", False),
                              ("conditional_forced_gate", True)):
            if enabled:
                baseline = results[0]
                v3_time = baseline["sent"][-1]["t_ms"]
                after_v3 = [item for item in baseline["events"]
                            if item.get("kind") == "guard" and item.get("document_version") == 3
                            and item.get("t_ms", -1) >= v3_time]
                justified = any(item["vfs_done"] and item["workspace_ready"]
                                and item["build_enabled"] and item["proc_enabled"]
                                and not item["build_last_none"] and not item["proc_last_none"]
                                and not item["build_in_progress"]
                                and not item["proc_in_progress"]
                                and not item["original_fetch_semantic"] for item in after_v3)
                if not justified:
                    print("CODESTRIKE_GUARD_EXPERIMENT_DECISION=no_counterfactual;"
                          "baseline did not observe the proposed blocking state after v3",
                          flush=True)
                    break
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                result = run_case(module, instrumented_binary, case,
                                  scratch / case, flag_path, enabled)
            results.append(result)
            print("CODESTRIKE_GUARD_EXPERIMENT=" +
                  json.dumps(result, separators=(",", ":")), flush=True)
        if len(results) == 2:
            print("CODESTRIKE_GUARD_EXPERIMENT_COMPARISON=" + json.dumps({
                "same_source_and_binary": True,
                "same_capabilities_config_fixture_and_edit_sequence": True,
                "same_readiness_barrier": all(result["barrier"] is not None
                                              for result in results),
                "baseline_push_v3_e0308": results[0]["push_v3_e0308"],
                "forced_push_v3_e0308": results[1]["push_v3_e0308"],
            }, separators=(",", ":")), flush=True)


def self_test():
    test = "before\n" + ORIGINAL + "\nafter\n"
    patched = patch_source(test)
    assert patched.count("CODESTRIKE_GUARD") == 1
    assert patched.startswith("before\n") and patched.endswith("\nafter\n")
    assert classify_guard("WARN CODESTRIKE_GUARD generation=7 document_version=3 " + " ".join(
        key + "=" + ("false" if key in ("build_last_none", "proc_last_none",
                                    "original_fetch_semantic", "experiment_requested",
                                    "fetch_semantic") else "true") for key in FIELDS))["fetch_semantic"] is False
    assert classify_guard("WARN unrelated") is None
    print("CODESTRIKE_GUARD_EXPERIMENT_SELFTEST=passed", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--instrument", type=Path)
    parser.add_argument("--compare", nargs=2, metavar=("PROBE", "INSTRUMENTED_BINARY"))
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.instrument:
        instrument(args.instrument)
    elif args.compare:
        compare(Path(args.compare[0]), Path(args.compare[1]))
    else:
        parser.error("Choose exactly one action")


if __name__ == "__main__":
    main()
