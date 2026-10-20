"""Offline, single-project app-server fixture. No model, account, or network use."""
import json
import pathlib
import sys


def receive():
    line = sys.stdin.readline()
    if not line:
        raise EOFError("client disconnected")
    return json.loads(line)


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    project = pathlib.Path(sys.argv[1])
    source = project / "fixture.rs"
    initial = receive()
    assert initial["method"] == "initialize"
    send({"id": initial["id"], "result": {}})
    assert receive()["method"] == "initialized"
    start = receive()
    assert start["method"] == "thread/start"
    assert pathlib.Path(start["params"]["cwd"]).samefile(project)
    assert start["params"]["sandbox"] == "readOnly"
    send({"id": start["id"], "result": {"thread": {"id": "fixture-thread"}}})
    for index in (1, 2, 3):
        turn = receive()
        assert turn["method"] == "turn/start"
        assert turn["params"]["sandboxPolicy"]["type"] == "readOnly"
        turn_id = f"fixture-turn-{index}"
        send({"id": turn["id"], "result": {"turn": {"id": turn_id}}})
        if index == 3:
            interrupt = receive()
            assert interrupt["method"] == "turn/interrupt"
            assert interrupt["params"] == {"threadId": "fixture-thread", "turnId": turn_id}
            send({"id": interrupt["id"], "result": {}})
            send({"method": "turn/completed", "params": {
                "threadId": "fixture-thread", "turn": {"id": turn_id, "status": "interrupted"}}})
            continue
        send({"method": "item/started", "params": {
            "threadId": "fixture-thread", "turnId": turn_id,
            "item": {"id": f"file-{index}", "type": "fileChange", "status": "inProgress",
                     "changes": [{"path": str(source), "kind": "update", "diff": "+changed"}]}}})
        send({"id": f"approval-{index}", "method": "item/fileChange/requestApproval",
              "params": {"threadId": "fixture-thread", "turnId": turn_id,
                         "itemId": f"file-{index}", "reason": "Edit fixture source"}})
        answer = receive()
        assert answer["id"] == f"approval-{index}"
        decision = answer["result"]["decision"]
        assert decision in ("accept", "decline", "cancel")
        if decision == "accept":
            source.write_bytes(b"fn changed() {}\n")
            send({"method": "turn/diff/updated", "params": {
                "threadId": "fixture-thread", "turnId": turn_id, "diff": "+fn changed() {}"}})
        send({"method": "serverRequest/resolved", "params": {
            "threadId": "fixture-thread", "requestId": f"approval-{index}"}})
        send({"method": "item/completed", "params": {
            "threadId": "fixture-thread", "turnId": turn_id,
            "item": {"id": f"file-{index}", "type": "fileChange",
                     "status": "completed" if decision == "accept" else "declined"}}})
        send({"method": "turn/completed", "params": {
            "threadId": "fixture-thread", "turn": {"id": turn_id, "status": "completed"}}})


if __name__ == "__main__":
    main()
