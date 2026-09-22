# Non-functional requirements

Not relevant as a separate spec: aidc is a single-machine tool with no load, latency, or scale
targets to tune for. The few properties that matter are rules in `docs/requirements.md` (for
example: refresher failure must not stop the proxy, NET-11; the supply-chain cooldown, REL-09).
Revisit if aidc gains a shared or hosted component.
