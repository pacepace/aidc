"""Tests for surfacing open-webhook sessions in the session-tool descriptions.

So the orchestrating LLM knows which session to talk to without remembering it:
the session-aware tools' descriptions carry a live list of sessions that
currently have an open webhook (an active watcher).
"""
from mcp.server.fastmcp import FastMCP

from aidc_mcp.tools import (
    _refresh_session_tool_descriptions,
    _session_watchers,
    _tool_base_desc,
    _watching_suffix,
)


class _StubTask:
    """Stands in for an asyncio.Task in _session_watchers (only the key matters)."""

    def cancel(self):
        pass


def _reset():
    _session_watchers.clear()
    _tool_base_desc.clear()


class TestWatchingSuffix:
    def test_empty_when_no_watchers(self):
        _reset()
        s = _watching_suffix()
        assert "No session is being watched" in s
        assert "OPEN WEBHOOKS" not in s

    def test_lists_watched_sessions_sorted(self):
        _reset()
        _session_watchers["beta"] = _StubTask()
        _session_watchers["alpha"] = _StubTask()
        s = _watching_suffix()
        assert "OPEN WEBHOOKS" in s
        # sorted, both present
        assert s.index("alpha") < s.index("beta")
        _reset()


class TestRefreshDescriptions:
    def _app_with_send(self):
        app = FastMCP("t")

        @app.tool()
        def session_send(name: str) -> str:
            "Send a prompt to the session."
            return name

        return app

    def test_appends_empty_state_then_session_list(self):
        _reset()
        app = self._app_with_send()
        _refresh_session_tool_descriptions(app)
        d0 = app._tool_manager._tools["session_send"].description
        assert d0.startswith("Send a prompt to the session.")
        assert "No session is being watched" in d0

        _session_watchers["myproj"] = _StubTask()
        _refresh_session_tool_descriptions(app)
        d1 = app._tool_manager._tools["session_send"].description
        assert "myproj" in d1 and "OPEN WEBHOOKS" in d1
        assert d1.startswith("Send a prompt to the session.")
        _reset()

    def test_idempotent_base_not_doubled(self):
        _reset()
        app = self._app_with_send()
        _session_watchers["a"] = _StubTask()
        _refresh_session_tool_descriptions(app)
        d1 = app._tool_manager._tools["session_send"].description
        _refresh_session_tool_descriptions(app)
        d2 = app._tool_manager._tools["session_send"].description
        assert d1 == d2
        assert d2.count("Send a prompt to the session.") == 1
        _reset()

    def test_reflects_removal(self):
        _reset()
        app = self._app_with_send()
        _session_watchers["gone"] = _StubTask()
        _refresh_session_tool_descriptions(app)
        assert "gone" in app._tool_manager._tools["session_send"].description
        _session_watchers.clear()
        _refresh_session_tool_descriptions(app)
        d = app._tool_manager._tools["session_send"].description
        assert "gone" not in d and "No session is being watched" in d
        _reset()

    def test_unknown_tool_name_is_skipped(self):
        # Only session-aware tools are touched; a missing one must not error.
        _reset()
        app = FastMCP("t")  # no session_send registered
        _refresh_session_tool_descriptions(app)  # must not raise
        _reset()


class TestRoutingCues:
    """Pin the cross-references that route 'ask the session's agent a question' to
    session_send. Twice now the orchestrator self-served via session_exec/file_get
    instead of delegating to the resident agent; these cues are the guard."""

    def _descs(self):
        from aidc_mcp import tools
        app = FastMCP("t")
        tools.register(app)
        t = app._tool_manager._tools
        return {n: (t[n].description or "").lower() for n in t}

    def test_session_send_frames_as_ask_the_agent(self):
        d = self._descs()["session_send"]
        assert "ask" in d and "agent" in d              # delegation framing, not just "conversation"
        assert "session_exec" in d and "file_get" in d  # steer away from self-serving

    def test_inspection_tools_point_to_session_send(self):
        d = self._descs()
        assert "session_send" in d["session_exec"]      # exec -> "ask the agent" via session_send
        assert "session_send" in d["file_get"]          # file_get -> session_send

    def test_session_invoke_distinguishes_fresh_from_resident_agent(self):
        d = self._descs()["session_invoke"]
        assert "session_send" in d and "fresh" in d     # not the resident, context-loaded agent
