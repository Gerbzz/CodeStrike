# Local agents and team collaboration candidate

Status: local process transport, a source-level Lapce side panel, and offline mock tests.
This candidate starts from `origin/main` in `draft/local-agent-adapter`. It is
local and unpublished; it does not replace the editor or modify PR #4 or the
design worktree. The panel has not been compiled or exercised in a GUI yet.

## First boundary: a local agent in CodeStrike

`src/agent_adapter.rs` models the documented Codex app-server stdio JSONL
handshake and a single thread and turn. It emits `initialize`, `initialized`,
`thread/start`, and `turn/start`, then classifies agent text deltas, aggregated
diffs, file-change lifecycle events, approvals, and completed/failed/interrupted
turns. It never approves automatically. Both thread and turn request `readOnly`
with `onRequest` approvals; a file edit or command requiring write access must
reach the host as a scoped approval request. The host must still render the
proposed operation and diff before an `accept` response; sandbox policy alone
is not a review UI or an audited isolation guarantee.

`src/agent_session.rs` owns a caller-selected local child process, its stdio
handshake, a 1 MiB maximum JSONL frame, a 256-event queue, and bounded UI polling.
The process is stopped on transport failure or session drop. The offline Python
fixture in `tests/fixtures/mock_app_server.py` proves that a declined file
change leaves exact source bytes unchanged, while an accepted request reaches
the file-change/diff/completion lifecycle and changes the fixture bytes. The
same fixture verifies `turn/interrupt` ends with an interrupted status and
does not change the accepted source bytes. This
is a mock app-server; no real account, model call, credential access, or Codex
binary was exercised. The host must still build the Lapce panel, show scope and
approvals, retain diff history, implement interruption/reconnect, and review
real workspace writes before claiming a usable agent feature.

The Lapce candidate now has a right-side Local Agent panel in the source patch.
It shows the selected local workspace, a caller-selected app-server executable
and model ID, prompt, transcript, proposed edit preview, and explicit approval,
decline, cancel, stop, and reconnect controls. The panel uses the same bounded
session adapter. `agent_review.rs` captures proposed updates to existing files
inside the workspace and fingerprints their bytes. It declines unsupported
changes and refuses an approval if the file changed after review. The panel
does not apply a patch itself: an accepted response authorizes the local agent
process under its requested sandbox policy. The current egui desktop is not
the intended host.

On this office machine, installed `codex-cli 0.141.0` answered `initialize` in
an isolated local home. The probe sent no thread, turn, model, or authorization
request. The pinned Lapce source still cannot be compiled offline here because
`winit` commit `ee245c569d65fdeacf705ee5eedb564508d10ebe` supplies the
uncached `dpi` dependency. The lockfile has 13 uncached Git sources and 527
registry package versions absent from this office cache. Resolving the first
dependency alone would not enable a local build. Until a Lapce build and
GUI interaction test pass, this is a source candidate, not an advertised
working panel. A completed agent turn is not proof that files are saved, shared,
reviewed, or safe to apply.

Codex protocol: <https://learn.chatgpt.com/docs/app-server>.

## Per-user sign-in and allowance

Sign in with ChatGPT (SIWC) is a possible per-user, local open-source access
path, subject to OpenAI eligibility and preview limitations. It must not be
described as a pooled team subscription or a free CodeStrike API. Each user
authorizes on their own device. A later implementation needs approved client
registration, stable per-host identifier, PKCE/state/nonce, OIDC verification,
secure local token storage, renewal, revocation, and explicit account state.
The Codex app-server integration uses a user's access token in the local child
process `ACCESS_TOKEN` environment with its configured Responses provider;
catalog results from `model/list` do not prove a user's entitlement. The
preview requires an app-server restart and thread resume when a token renews.
No credential or OAuth code belongs in this source-only branch.

Official references: <https://developers.openai.com/siwc/token-sharing-open-source/>,
<https://developers.openai.com/siwc/token-sharing-open-source/sign-in>,
<https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server>,
<https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations>.

OpenCode can be a separate opt-in local adapter rather than a dependency of the
first milestone. Its server uses a localhost HTTP API and may use HTTP basic
auth; a remote or unauthenticated listener must never be silently enabled.
Reference: <https://opencode.ai/docs/server/>.

## Team collaboration scope

The requested delta.dev experience is a product reference only. Neither its
application source nor Zed's DeltaDB source/license was verified as reusable.
Do not copy either or claim live replicated editing from this branch.

The first shippable team milestone would share thread metadata, comments, and
reviewed patches with explicit project/revision identities. Agent processes
and tokens stay on each contributor's host. A team service must receive no
OAuth token, app-server transcript by default, or unreviewed workspace write.
Before real-time co-editing, design conflict resolution, offline rejoin,
workspace permissions, presence, and audit/recovery; then test divergent
edits on separate hosts. No team service is implemented here.

## Unity editor workflow

The user-facing target is Bezi-like Unity work inside CodeStrike: live scene,
prefab, component, script, asset, and package context; selected-object pins;
Ask/Plan/Agent flows; validated editor actions; checkpoint/diff/Keep/Undo;
and compile, Play, EditMode/PlayMode test, Console, and screenshot feedback.
Bezi says its own in-editor Actions use a custom engine integration rather
than MCP for mutation. A generic MCP chat connection alone does not meet this
target. See <https://docs.bezi.com/context/index-project> and
<https://docs.bezi.com/fundamentals/agent-mode>.

`src/unity_action.rs` is the next source-only gate: a host-supplied snapshot,
opaque revision, known scene/object IDs, and checkpoint must match a typed
action before a writer lease is granted. Unsaved scenes require an explicit
checkpoint that covers memory state. The prepared request cannot be modified
or cloned. The future Unity-side executor must recheck revision and IDs at
execution time and capture a real restorable checkpoint. No snapshot reader,
checkpoint writer, Unity-side validator, or action executor exists yet.

Unity's current first-party route is the Unity CLI and Pipeline package for
Unity 6+, with `unity mcp` or direct `unity command`/`unity eval`; the older
`com.unity.ai.assistant` in-editor MCP server is deprecated. The CLI is free to
use, but it is not an open-source component to vendor into CodeStrike and its
installation requires Unity sign-in. No CLI or Pipeline package is installed
by this branch. See
<https://docs.unity.com/en-us/unity-cli/replace-mcp-server-unity-cli> and
<https://docs.unity.com/en-us/unity-cli/unity-pipeline/unity-pipeline-package>.

## Optional open-source Unity transport

The recommended upstream is CoplayDev `unity-mcp`, MIT-licensed. The pinned
candidate is tag `v10.3.0` (tag `ba6881930eadb2a9006d28bff3325ce03b4bfd8a`,
commit `aa5fc638d623f56178d50329d9ad8c541a57fe66`), with package
`com.coplaydev.unity-mcp` version `10.3.0`. Do not vendor or bundle it until
the package, server dependencies, and license notice have been reviewed and
tested together. If bundled, include the MIT notice and attribution.
Another MIT candidate is <https://github.com/CoderGamester/mcp-unity>, using
a Node server and Unity Editor package. Compare actual supported Unity versions,
tool behavior, reconnect handling, transitive dependencies, and notices before
choosing a transport. Neither transport replaces the CodeStrike revision,
checkpoint, and review layer.

`src/unity_writer.rs` is an in-memory lease contract with mock tests. It blocks
overlapping writes to one project/instance and holds an unknown outcome after
transport loss until the host records inspection. It is not crash durable and
does not coordinate separate CodeStrike processes; those requirements must be
solved before enabling Unity mutations.

`src/unity_connection.rs` adds a read-only first connection boundary. It
recognizes a local Unity project from `Assets` and
`ProjectSettings/ProjectVersion.txt` without changing either. Its MCP state
machine sends `initialize`, `notifications/initialized`, and bounded,
paginated `tools/list` requests. It never emits `tools/call` or a model request.
It rejects unsupported protocol versions and unsolicited server requests.
This is a source contract tested with mock frames, not a live Unity connection:
there is no process transport, verified editor instance, or Unity installation
in this branch. The message shapes follow the
[official MCP lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)
and [tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
specification.

The CodeStrike flow should discover a local Unity project and running editor,
guide installation of the Unity package and Python server, display connection
and capability status, and let the user pick one Unity editor instance. One
writer lease per `{project, instance}` must guard mutating tools. A lease must
not be inferred as released after a timeout or transport loss: reconnect,
inspect Unity state, and ask the user before retrying an ambiguous mutation.
Test domain reload, editor restart, two windows targeting one project, and
failed commands before advertising a built-in integration. No Unity editor or
Unity MCP server is installed or started by this branch.

Upstream: <https://github.com/CoplayDev/unity-mcp/tree/v10.3.0>.

## Acceptance gates

1. Hosted contract tests pass for the adapter's handshake, scoped turn request,
   approval surfacing, error states, bounded frames, Unity writer leases, and
   snapshot/revision/checkpoint action gating.
2. The local mock-process test covers initialize, thread, turn, approval, file
   change, diff, completion, interruption, stale files, decline, and reconnect.
   The real `initialize` probe does not exercise thread/turn or reconnect.
3. GUI tests prove prompt/transcript, project scope, human approval, diff review,
   save/reopen, and a failed turn. Two-host tests prove sharing and conflicts.
4. SIWC eligibility, registration, account lifecycle, limits, and token handling
   receive separate security and product review before implementation.
5. Unity packaging and license review precede any bundle; real Unity tests
   cover reconnection and the single-writer rule.

No paid runner, credential, server deployment, or local build is required for
this candidate. The office machine's 20 GiB free-space floor takes priority.
