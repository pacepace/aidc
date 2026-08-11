# release/

Machinery for cutting an aidc release. Nothing here is invoked directly by
end users or by the `aidc` CLI -- it is driven by
`.github/workflows/release.yml` on a pushed `v*` tag.

| File | Purpose |
|------|---------|
| `Formula/aidc.rb.tmpl` | Template for the **unversioned** Homebrew formula (always points at the latest release). The workflow substitutes `__VERSION__`, `__SHA256__`, `__VERSION_TAG__` and commits the result to the tap repo. |
| `Formula/aidc@version.rb.tmpl` | Template for the **versioned** formula `aidc@MAJOR.MINOR.rb` (parallel-installable, `keg_only`). Adds `__VERSION_TAG_SAFE__`. |
| `lint-formula-template.sh` | Rejects any Ruby execution construct in the templates outside the documented allowlist. Run by CI (`.github/workflows/ci.yml`) and intended for `make lint`. These templates run unprivileged on every user's machine via `brew install`; this is a security gate. |
| `tarball-audit.sh` | Pre-release gate: greps the **git tree** of the tagged commit for files that must never ship (`tests/scratch/`, session `audit/` dirs, `.env*`, keys, cert stores). Allowlists `proxy/audit/` (legit sidecar source). |
| `tarball-audit-extracted.sh` | Pre-release gate: same patterns against the **downloaded tarball** (`tar tzf`), catching `.gitattributes` export divergence. Requires GNU tar. |

## Why templates live here but the rendered formula lives elsewhere

A Homebrew tap must live in a repo named `homebrew-<name>` -- users run
`brew tap pacepace/aidc`, which resolves to `github.com/pacepace/homebrew-aidc`.
So the *rendered* `Formula/aidc.rb` is committed to that separate tap repo by
the release workflow. The *templates* and the *automation that renders them*
live here, where they get code review via CODEOWNERS.

The repo-root `Formula/aidc.rb` is a bootstrap/reviewable copy (see
`Formula/README.md`); the authoritative rendered artifact is the one the
workflow writes to the tap.

See `docs/release-process.md` for the operator-facing release walkthrough.
