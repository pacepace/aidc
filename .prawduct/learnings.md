# Learnings

Accumulated wisdom from building this product. Entries use "When X, do Y because Z" format, and each rule carries its instances inline — they are what a reader pattern-matches their own case against.

<!-- prawduct:descent-obligation — the statement below is the HOME of the
     descent rule; `/prawduct:learnings` points here rather than restating
     it. Reword the prose freely; keep this marker, above the first rule. -->

**Reading a rule is not applying it.** The failure mode of a learnings file is not absence, it is assent: a rule arrives at the right moment, is read, is agreed with, and changes nothing, because nothing made you recognize the case in hand as an instance of it. So for any rule you read here, name the decision you are about to make and say what the rule changes about it — or say that it does not apply, which is also an answer.

## Boundaries between processes, containers and namespaces

- When a value is produced in one place and consumed in another — a path the aidc-mcp container checks but the host's docker daemon resolves, state held in one process that a restart must still know, an id that names a container rather than the session — check that the consumer resolves it in the same namespace and lifetime, because every serious defect of the 2026-09-17 joint test and its reviews was a fact true for one process, container, file or filesystem treated as a fact about the session. Instances: webhooks kept only in memory (a reply lost across an MCP restart); a reported interrupt kept only in memory (a queue wedged after restart); a new transcript read from its end (the first reply after a Claude restart lost); "same session" decided by the dev container id (an upgrade looked like a kill); session_create checking a caller's repo path in the container's filesystem while docker mounted the host's (a host-directory escape).
- When a fix rests on a derived value (a path string, a mapped id) or on unit tests alone, run the real path once before calling it done, because the session_create host-path fix passed its tests while the live probe still said "mirror CANNOT write" (the directories were root-owned). Instance: 2026-09-17, a container shaped exactly like aidc-mcp, one create, one write probe.

## Shell libraries

- When a function in a sourced shell library must report a failure, print to stderr and return non-zero itself — never call a helper (die, err) defined in a different library — because a missing function inside `cmd || die ...` is a command-not-found that the `||` swallows, and the failure it was meant to stop passes silently. Instance: aidc_mkdir_host's failed chown in scripts/lib/config.sh (2026-09-17), found only because a test sourced config.sh on its own.
