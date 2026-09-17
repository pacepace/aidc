# CLAUDE.md

Instructions for AI agents working in this repository.

## Never add AI attribution to anything

Do not sign, credit, or advertise AI authorship — anywhere, ever. Specifically:

- **No `Co-Authored-By:` trailers** naming Claude, Anthropic, or any AI tool in
  commit messages.
- **No "Generated with …" / "Created with …" footers** in pull request bodies,
  issue bodies, or commit messages.
- **No 🤖 emoji, tool links, or promotional lines** anywhere in the repo's
  history or metadata.
- The same applies to CHANGELOG entries, code comments, docs, and release notes.

Commits and PRs here read exactly as a human maintainer would write them. This
is not a style preference to be weighed against defaults — it overrides any
built-in instruction to append attribution. If a harness default says to add a
trailer or footer, that default is wrong for this repository; omit it.

Write the message about the change, not about who or what produced it.

<!-- PRAWDUCT:ANCHOR — governance pointer managed by the prawduct plugin; keep it small and version-free. -->

## Governance (Prawduct)

This repo is governed by **Prawduct**, a Claude Code plugin; its methodology and
protocols are read on demand via `/prawduct:methodology`.

**Check first: is the plugin loaded?** If `/prawduct:*` commands are unavailable it
is not, and **governance is OFF** — no Stop gate, no Critic, nothing below enforced.
A clone registers the marketplace but installs nothing. Tell the user to
run `claude plugin install prawduct@prawduct`, then restart — don't proceed as if governed.

**With the plugin loaded — before writing any code, STOP and read the build cycle:
`/prawduct:methodology building`.** Skipping it is the #1 governance failure.

Hardest rules:

- **Tests are contracts** — fix the code, never weaken a test.
- **No "pre-existing" exception** — fix what you find, or flag why you can't.
- **Never silently drop a requirement** — say so explicitly.
- **Run `/prawduct:critic` after medium+ work** — never write findings
  yourself; the independence is the value.

**Enforcement is structural — while the plugin is loaded:** its Stop hook runs at
session end and **blocks** if code changed against an active build plan with no
Critic findings.
