# Design 02 — Git Isolation

**What this covers.** The asymmetry that lets Claude do arbitrary local git work (branch, commit, rebase, stash) while making it impossible to publish anything to a remote. This is the cornerstone of "Claude can't ship malicious code on your behalf."

**Requirements implemented:** GIT-01 through GIT-06.

---

## The asymmetry, at a glance

| Capability | Container | Host |
|------------|-----------|------|
| `git status / diff / add / commit` | ✅ | ✅ |
| `git branch / checkout / rebase / stash / cherry-pick` | ✅ | ✅ |
| `git log / blame / show / reflog` | ✅ | ✅ |
| `git merge / format-patch / am` (local-only) | ✅ | ✅ |
| `git push / pull / fetch / clone <remote>` | ❌ | ✅ |
| `gh` (GitHub CLI) | ❌ (not installed) | ✅ |
| SSH-based git remotes | ❌ (no agent, no keys) | ✅ |
| HTTPS-based git remotes | ❌ (no credentials, blocked by proxy where applicable) | ✅ |

Inside the container, Claude has the **full power** of git for everything that touches only the local repo. The moment any operation needs a network or a credential, it fails.

---

## How the asymmetry is enforced

Three independent layers. Each one alone would mostly work; together they make remote git operations functionally impossible.

### Layer 1 — Credential denial (primary)

The container has no usable credentials for any remote:

- **No SSH keys.** `~/.ssh/` is not mounted (CTR-07).
- **No SSH agent.** `$SSH_AUTH_SOCK` is unset; the host agent socket is not mounted (CTR-07).
- **No GitHub token.** Neither `gh` config nor environment-variable tokens (`GITHUB_TOKEN`, `GH_TOKEN`) are present (CTR-08).
- **No git credential helpers.** The system `.gitconfig` does not configure any credential helper. The container's `~/.gitconfig` is generated fresh at post-create with user identity but no credentials.

Result: any `git push`, `git fetch`, or `git clone <remote-url>` will hit an auth failure. The remote server will refuse the operation.

### Layer 2 — Network egress filtering (secondary)

Even attempts that try to use HTTPS without credentials (or that try to inject credentials at the URL) are subject to the proxy stack (`design-04-proxy-stack.md`):

- Outbound HTTPS to `github.com` is permitted (it's needed for `git clone` of public repos and various legitimate fetches)
- But without credentials, push operations get a 401/403 from the GitHub side
- SSH-based remotes (`git@github.com:...`) require port 22 outbound and an authenticated SSH session — neither is available

The proxy doesn't actively block git pushes by URL pattern; it doesn't need to. The credential layer is sufficient. The proxy is the safety net.

### Layer 3 — Pre-push hook (belt-and-suspenders, GIT-05)

For paranoia, the container ships a system-level pre-push hook:

```
/etc/git-hooks/pre-push    (exits non-zero unconditionally)
```

Activated via:

```
git config --system core.hooksPath /etc/git-hooks
```

Effect: even if a credential somehow leaks into the container (a user accidentally pastes a token, a script writes one), `git push` is still blocked at the local git layer before any network call happens. The hook is unconditional — there is no environment toggle to bypass it from inside the container.

This layer is marked **P1** (not P0) because the credential denial in Layer 1 is the actual guarantee. The hook exists to catch developer error, not as a primary defense.

---

## What the human flow looks like

Claude works in the container:

```
# inside container
git checkout -b feat/saoirse-rules-the-world
# ... edits, tests ...
git add -A
git commit -m "feat: add Saoirse to the ruling council"
```

Push is impossible from here. The branch lives in the container's view of the host-mounted repo.

Pace, on the host, sees that branch in the same working tree (because the repo is bind-mounted):

```
# on host
cd ~/myrepo
git log feat/saoirse-rules-the-world
git diff main..feat/saoirse-rules-the-world
# ... review ...
git push -u origin feat/saoirse-rules-the-world
```

The split is intentional: Claude does the local work, the human is the gatekeeper for anything that leaves the machine.

---

## Edge cases and gotchas

### Submodules

Submodule operations (`git submodule update --init`) require fetching from remotes. These will fail inside the container for the same reason `git fetch` fails. Workaround: initialize submodules on the host before starting the session, or vendor them.

### Git LFS

LFS objects are fetched over HTTPS using credentials. Without credentials, LFS pull/push fails. If a project uses LFS, the human pulls LFS objects on the host before starting a session.

### Refs from URL-embedded tokens

A user (or Claude in a worst case) could in principle `git remote set-url origin https://user:token@github.com/...`. Layer 1 wouldn't have stopped this if a token were available — but tokens aren't available in the container. Layer 3 (the pre-push hook) catches this if it happens anyway.

### Local-only remotes

Git operations against local paths (`git remote add other /workspaces/other-repo`) work, because they don't touch the network. This is a feature, not a bug — it allows Claude to work across multiple mounted repos.

### Reflog and lost commits

Reflog inside the container is preserved across the container's lifetime but lost on `aidc kill`. The host-mounted `.git/` directory IS shared, so reflog entries that get into `.git/logs/` persist. Practically: don't kill a container while you're mid-recovery-from-a-mistake. Commit the recovery first.

---

## Why not just `git config --global push.default refuse`?

Two reasons:

1. **It's per-config**, so it's only as strong as nobody overriding it. Claude in `--yolo` mode is allowed to run `git config` commands; we can't rely on a soft config setting.
2. **It's a single point of failure.** A system-wide pre-push hook (Layer 3) survives `git config --global` resets and is much harder to disable from a normal user shell.

The chosen design (credentials denied at mount layer + optional system hook) requires root-level container changes to break, which Claude in yolo mode does have, **but** the container is ephemeral — any modification Claude makes to the system config is destroyed at `aidc kill`. The host repo only ever sees the committed work product.

---

## Things this design does NOT prevent

Being honest about the threat surface:

- Claude can write a bad commit. The asymmetry stops it from publishing the commit; it does not stop the commit from existing locally. The human review on the host is the publishing gate.
- Claude can rewrite local history (rebase, force-update branches, delete branches). The host sees the new state. This is desirable behavior for normal dev work; if it isn't desired, branch protection at the host's review step is the answer.
- Claude can stage and commit secrets that exist in the working tree. The asymmetry stops the secret from being pushed, but the commit itself is in `.git/`. If the host then pushes that branch, the secret goes with it. Mitigation: secrets shouldn't be in the working tree to begin with; the proxy stack and credential-denial keep new ones from being fetched.

---

## References

- Git system-level config and hooks: https://git-scm.com/docs/git-config
- Dev Container `mounts` field: https://containers.dev/implementors/json_reference/
