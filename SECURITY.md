# Security Policy

aidc exists to run an autonomous coding agent in `--dangerously-skip-permissions` mode
*safely* — the whole project is a security boundary. Reports about that boundary are taken
seriously.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** — do not open a public issue for a
security problem.

- Preferred: open a private [GitHub security advisory](https://github.com/pacepace/aidc/security/advisories/new).
- Or email the maintainer: `pace@pace.org`.

Please include enough detail to reproduce: the aidc version (`cat VERSION`), your host OS,
and the steps or configuration that trigger the issue. A sandbox-escape proof-of-concept
(anything that reaches the host, exfiltrates credentials, or defeats the egress proxy /
taint detection) is the highest priority.

You can expect an acknowledgement within a few days. Please give a reasonable window for a
fix before any public disclosure.

## Supported versions

Security fixes land on the latest released version only. There is no long-term-support branch;
upgrade to the newest release (`git pull` + `aidc rebuild` + `aidc upgrade <session>`) to stay
covered.

| Version | Supported |
|---------|-----------|
| latest release | yes |
| older releases | no — upgrade to the latest |

## Threat model

What aidc defends against, what it explicitly does **not**, and the trust boundaries between
host, dev container, proxy, and control plane are documented in the safety model:
[`docs/done/design-07-safety-model.md`](docs/done/design-07-safety-model.md). Read it before
reporting so we can tell an in-scope escape from an accepted, documented limitation.
