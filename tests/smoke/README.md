# aidc smoke tests

End-to-end harness that proves aidc's isolation guarantees actually hold. It
creates a real session, asserts behaviours against the live containers, and
tears everything down. This is what `make smoke` runs.

## Run

```bash
make smoke
# or:
bash tests/smoke/run.sh
```

Expected: all assertions pass, exit code 0.

## Prerequisites

- Docker (engine reachable; `docker info` succeeds)
- `docker compose` plugin (v2)
- `jq`, `curl`, `git` on PATH
- Network access to `example.com` and `example.org`, and to `github.com` for the git
  container's part

The smoke writes everything (repo mount, audit dir) to `tests/scratch/<session>/`
INSIDE the repo. That dir is gitignored. Nothing lands in `/tmp/`, `mktemp -d`,
or `~/aidc-audit/`; the per-project `.aidc/config.yaml` written into the scratch
repo overrides the global `audit_dir`. This is deliberate -- it keeps the
smoke self-contained and avoids macOS TCC prompts.

The smoke spins up 5 containers (dev, squid, refresher, policy, audit), and for the
git container's part a second session and the git container with its proxy, for a few
minutes, then tears them down. Wall clock varies with image
build cache; first run on a clean machine will be slower because images get
built.

## What it covers

Verifies the P0 requirements that span multiple shards:

| Step | Requirement IDs | Asserts |
|------|----------------|---------|
| 2 | CTR-09, GIT-03 | no docker.sock leak, no `gh`, no SSH/token leak |
| 3 | GIT-02 | local git works, push fails, pre-push hook installed |
| 4 | DKR-01 | inner Docker daemon up, can't see host containers |
| 5 | NET-01/02/04/05 | example.com allowed, `.cn` TLD blocked, blocklist enforced |
| 6 | SEC-03 | malware hit writes `/var/state/tainted` (valid JSON) |
| 7 | SEC-03 | `aidc status` and `aidc list` surface the taint |
| 8 | -- | audit dir on host has `squid-access.log`, `policy-events.log` (with a `"outcome":"tainted"` line), `meta.json`, `config-snapshot.yaml`; lives under in-repo scratch (no host pollution) |
| 9 | SEC-06 | `aidc kill` removes all containers, preserves audit dir on host |

The TLD-only-does-not-taint (SEC-04) case is exercised implicitly: the `.cn`
block in step 5 fires before the malware injection, and if the policy sidecar
were tainting on TLD hits the tainted flag would appear before step 6's
malware injection. The default `tld_taints=false` is what we're checking.

## The git container (step 9b, and `make smoke-k8s` step 4b)

Both smokes include the git container (`tests/smoke/git.sh`, shared). `AIDC_SMOKE_GIT=0` skips
it in `make smoke`.

**Always (no login needed):** `aidc git setup` and `status`; a public repo
(`AIDC_SMOKE_PUBLIC_REPO`, default `octocat/Hello-World`, only ever fetched) added with
`aidc repo add` and listed; a session created after setup has the request folder, its 64-hex
git token and the `gh` stand-in, and cannot list requests; it makes its own worktree and branch
and commits; `git push` explains; `gh pr create` waits in ask mode; `aidc git requests` lists it;
`aidc git deny` reaches the session with the reason; `aidc git mode <session> rules` is recorded
and listed. While the git container is **not** logged in to GitHub, also: in rules mode the
request runs at once and fails only for the login; `aidc git approve` runs one and fails only
for the login; `aidc git tidy` reports the unpushed branch. (Logged in, those three would push to
the public repo, so they move to the GitHub part.) The git agent is a session: `aidc list` shows
`git`, `aidc kill git` and `aidc create git` are refused. Then the repo is removed.

On Docker, when this machine had no git container, the run removes everything it made
(containers, networks, volumes, the git agent's transcript folder); one you already had is left
as it was, apart from being restarted, as `aidc repo add|remove` restart it.

**With a GitHub login** (`aidc git login`) **and a scratch repo you own:**

```bash
AIDC_SMOKE_GIT_REPO=<you>/<scratch-repo> make smoke        # or make smoke-k8s
AIDC_SMOKE_GIT_REPO=<you>/<scratch-repo> AIDC_SMOKE_GIT_PROTECT=1 make smoke   # also turn protections on
```

A session's branch is pushed and a PR opened (rules mode for that session), `aidc git merge`
merges it with a merge commit (two parents on the default branch) and tidies (the branch deleted
on GitHub, the session's worktree removed), the session sees it merged, the git container's
commit identity is set, and `aidc git protect` reads the protections (answering no unless
`AIDC_SMOKE_GIT_PROTECT=1`). Only that repo is touched. Each run adds one file under
`aidc-smoke/` to its default branch through the merged PR; if a step fails after the PR opened,
cleanup merges it (or says what it left).

**With the git agent's Claude logged in** (`aidc git attach`, log in, finish its first-run
screens) and your git mode ask:

```bash
AIDC_SMOKE_GIT_CLAUDE=1 make smoke
```

A request reaches the agent, which asks with its question tool (seen in its transcript, naming
the session); `aidc git deny` then answers it.

**By hand: an orchestrator answers the git agent's question (Docker).** With aidc-mcp running and
an orchestrator connected:

1. In the orchestrator, `session_watch git`.
2. In a session created after setup, on an added repo: `gh pr create --title t --body b`
   (it waits).
3. The orchestrator receives the git agent's question as session `git`'s reply.
4. Answer with `session_send git "Approve"` (or `"Deny: <why>"`). The result's `git_request`
   says `done: true`: aidc's MCP server ran `git-requests approve|deny` as gitreq for the
   request the question names (design-10 S10), with `git_request_answered` in its access log.
   Check that the request is approved or denied as chosen (`aidc git requests`), that the
   session reads the result (`gh pr status`), and that the question was answered (`aidc attach
   git`). If paste and Enter do not answer the question, record it: the decision stands
   either way, but the agent's turn then needs another way on.
5. Send `"Approve"` again for the same question: `git_request.code` is
   `git_request_not_waiting`, and nothing runs twice.

On Kubernetes the question does not reach an orchestrator until aidc 2.0's per-user MCP server.

## What it does NOT cover

- Claude Code is never invoked in a session (the git agent's Claude only with
  `AIDC_SMOKE_GIT_CLAUDE=1`). This is a sandbox test.
- The Phase 2 HTTP API is not exercised.
- Performance / load characteristics.
- Multi-session interference (only one session is created).
- Cross-platform path quirks (Linux + macOS host paths only).

## Debugging a failure

Set `AIDC_SMOKE_PRESERVE=1` to skip the cleanup trap when the run exits
non-zero:

```bash
AIDC_SMOKE_PRESERVE=1 make smoke
```

The script prints the session name and audit dir on failure so you can:

```bash
aidc status <session>
aidc attach <session>
docker logs aidc-<session>-policy
docker logs aidc-<session>-squid
ls -la <audit-dir>
```

Tear down manually when done:

```bash
aidc kill <session>
```

## Design notes

- The session name is `smoke-$(date +%s)` so reruns never collide and never
  shadow a user's real session.
- The cleanup trap runs on `EXIT`, `INT`, and `TERM` so Ctrl-C never leaks
  containers. Set `AIDC_SMOKE_PRESERVE=1` to opt out for debugging.
- The audit dir is parsed from `aidc create` output (the `audit:` line) which
  is the canonical place that path is surfaced. `aidc status` does not print
  it, so we capture it at create time.
- Assertions test file presence and content patterns -- never log line
  counts -- because Squid logging is non-deterministic.
- A blocklist refresh is exercised for real (the refresher's own script, while
  requests stream through the proxy) and must drop no connection: squid never
  reloads for a new list, its lookup helper follows the file (NET-16). The malware
  test domain is then added the way the refresher writes the file: a sorted copy
  renamed over it.
