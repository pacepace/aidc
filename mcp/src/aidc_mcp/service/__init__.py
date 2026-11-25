"""The aidc service: everything the MCP server does that is not MCP.

Watchers, send queues and drainers, delivery with retry and dead letters, resume on
start, persisted state and the session operations, in modules that import no MCP
type (test_service_boundary). tools.py adapts them to MCP tools; aidc 2.0 adapts
them to 3tears tools (docs/design-13-3tears-tools.md).

Modules refer to each other as `alias.name` (`ss.pending_sends`), never through
`from module import name`: one binding per name, read at call time.
"""
