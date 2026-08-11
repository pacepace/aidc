# Design 06 — Remote Control

**What this covers.** How humans (Phase 1) and an external orchestrator (Phase 2) interact with a running aidc session. Phase 1 — tmux + `docker exec` — is fully designed here. Phase 2 — an HTTP control API for Saoirse — is **sketched only**, with a strong design principle around sidecar isolation. Full Phase 2 spec is deferred.

**Requirements implemented:** CTR-12 (long-lived tmux session) and CLI-04 (interactive attach: observe, interrupt, take over) for Phase 1; the MCP control plane (MCP-01..MCP-19) for Phase 2. (Formerly RMT-01..RMT-04 — the RMT section is now retired; see `docs/requirements.md`.)

---

## Phase 1 — Human-direct (in scope for v1)

### Model

The dev container runs a single, long-lived `tmux` session named `main`. Claude Code runs inside that tmux session — the container's PID 1 is `tmux`, started by the entrypoint. Claude is `tmux send-keys`-driven into a window inside `main`.

Pace attaches with:

```
aidc attach my-session
```

Which executes:

```
docker exec -it aidc-my-session-dev tmux attach -t main
```

This drops Pace's terminal into the tmux session. He sees whatever Claude is doing in real time. He can:

- Observe silently.
- Type into Claude's input (interrupting if necessary).
- Open new tmux windows / panes (Ctrl-b c) to run his own commands inside the same container — useful for `git diff`, `tail -f` of logs, etc.
- Detach (Ctrl-b d) without disturbing Claude.

### Why tmux

- Survives client disconnects — the underlying processes (Claude, any commands) keep running when the attach terminal drops.
- Multi-client by design — multiple humans can attach to the same session and share a view.
- Standard tooling, no custom protocol.
- Lightweight (~3 MB resident).

### What lives in the tmux session

By convention, the dev container's tmux session has named windows:

| Window | Purpose |
|--------|---------|
| `claude` | The Claude Code CLI process |
| `shell` | A plain interactive shell for the user to use |
| `logs` | A pre-arranged tail of relevant logs (Claude's own logs, etc.) |

The window layout is set by the dev container's `postCreateCommand` so it's identical every session.

### Detach behavior

Detaching (Ctrl-b d) returns Pace to his host shell. The container keeps running. `aidc list` still shows the session as `running`. `aidc attach my-session` reattaches at any time.

### "Take over from Claude"

There is no formal "stop Claude, hand control to human" mode in v1. The pragmatic version is:

- Pace attaches.
- He uses tmux's input to interrupt Claude (e.g., Ctrl-C in Claude's window) or types instructions.
- When done, he detaches; Claude resumes whatever he left it doing.

If the user wants harder isolation (e.g., kill Claude entirely while keeping the container alive to inspect it), that's `aidc kill` followed by manual `docker run` against the same image — but tainted/lost work concerns make this an unusual flow. v1 doesn't ship a built-in "freeze Claude only" command. (Could be added later as `aidc claude pause`. P2.)

### Logging human activity

Anything Pace does in the tmux session is captured in:

- The container's shell history (~/.bash_history) — picked up by the audit aggregator
- Tmux's own pane-history buffer (in-memory, lost on container kill)

For high-stakes sessions, the audit aggregator can be configured to run `tmux pipe-pane` against each window to capture full output to a file. Tagged P1 because it's noisy and not always wanted.

---

## Phase 2 — AI-orchestrated (sketch only)

### Goal

Saoirse — an LLM-driven orchestrator running on a long-lived host, reachable from anywhere via Tailscale — needs to:

- Spin up aidc sessions on demand.
- Send commands into the dev container (run Claude with a task, inspect output, edit planning docs, etc.).
- Receive back structured results.

This is **not** about replacing Pace. Pace still controls deployment — Saoirse can request actions, but session lifecycle and the host is still Pace's domain. Phase 2 adds a programmatic interface alongside the existing tmux interface.

### Critical isolation requirement (MCP-12, formerly RMT-04)

If the HTTP control API runs **inside** the dev container, Claude in yolo mode can subvert it:

- Edit the API's code (it's running in the same container).
- Read its secrets / API keys.
- Issue arbitrary commands "as Saoirse" by hitting localhost.
- Tamper with audit data captured by the API.

**Therefore: the HTTP control API runs as a sidecar container with its own network namespace.** Specifically:

- It is part of the per-session compose stack (alongside Squid, refresher, policy, audit).
- It is on a separate Docker network from the dev container.
- It mounts a control-only socket / API endpoint **into** the dev container at a known path (read-write from the API container, **read-only** or unwritable from the dev container).
- Claude inside the dev container cannot reach the API by IP/hostname — Docker network isolation blocks that.
- The API container has Tailscale (or equivalent overlay) so Saoirse can reach it from outside.

The API container is essentially in a different security domain from the dev container. Claude can be exposed to commands *from* it (via the read-only-from-Claude file or socket) but cannot send commands *to* it.

### Endpoints (rough sketch — not v1 spec)

- `POST /sessions/<name>/exec` — run a command in the dev container, return stdout/stderr/exit
- `POST /sessions/<name>/claude` — invoke Claude Code with a prompt or task file
- `GET /sessions/<name>/files/<path>` — read a file from the host-mounted repo
- `PUT /sessions/<name>/files/<path>` — write a file (with audit logging)
- `GET /sessions/<name>/status` — same data `aidc status` shows, in JSON
- `POST /sessions/<name>/taint` — mark tainted (manual; for when Saoirse sees something wrong)

All endpoints require authentication. v2 details (token format, key management, audit log of API calls) are deferred until we get there.

### How a request flows

1. Saoirse (on its long-lived host) sends `POST /sessions/my-feature/exec` over Tailscale.
2. The API container (on Pace's host inside `aidc-my-feature` stack) authenticates the request.
3. It writes a command file into a shared volume mounted into the dev container at, e.g., `/var/aidc/cmd/`.
4. A small daemon inside the dev container watches that path, executes commands, writes results to `/var/aidc/result/`.
5. The API container reads the result and returns it to Saoirse.

The dev container's daemon is the only thing the API container can ask to run code. It cannot, e.g., reach into the dev container with `docker exec` (the API container does not have the host Docker socket).

### Why not just expose `tmux` over the network?

We considered it. Tmux's own multi-client mode would technically let Saoirse attach over TCP. We rejected it because:

- Tmux's network exposure isn't built for security; there's no good auth model.
- The interface would be terminal-emulator-driven; Saoirse would need to parse screen output. Brittle.
- A small purpose-built HTTP API is easier to lock down and easier for an LLM to drive.

### Status of Phase 2

- Marked **P2** in requirements.
- Not built in v1.
- The v1 design leaves room: compose stack templates can accept additional services without re-architecture. Adding the API container is additive.

---

## What `aidc attach` cannot do

For clarity, the v1 attach mechanism does not include:

- Network-attach from a remote machine (it's local `docker exec`)
- Multi-session aggregation (you attach to one session at a time)
- Direct file editing outside the tmux session (use the host's editor on the mounted repo, or run a tmux pane with `$EDITOR`)
- "Replay" of past attach sessions (audit aggregator captures shell history but not full terminal output by default)

---

## References

- tmux multi-client / multi-window: https://github.com/tmux/tmux/wiki
- Tailscale: https://tailscale.com/
