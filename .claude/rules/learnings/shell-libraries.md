---
paths:
  - "scripts/**/*.sh"
  - "tests/unit/*.sh"
  - ".devcontainer/*.sh"
  - "proxy/**/*.sh"
---

# Shell libraries

- When a function in a sourced shell library must report a failure, print to stderr and return non-zero itself — never call a helper (die, err) defined in a different library unless the library loads that one itself (`declare -F die >/dev/null || . .../common.sh`) — because a missing function inside `cmd || die...` is a command-not-found that the `||` swallows, and the failure it was meant to stop passes silently. Instance: aidc_mkdir_host's failed chown in scripts/lib/config.sh (2026-09-17), found only because a test sourced config.sh on its own. tests/unit/test-lib-self-contained.sh checks every sourced library under scripts/ for it (2026-11-28).
