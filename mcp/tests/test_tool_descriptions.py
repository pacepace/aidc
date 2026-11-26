"""Tests for surfacing open-webhook sessions in the session-tool descriptions.

So the orchestrating LLM knows which session to talk to without remembering it:
the session-aware tools' descriptions carry a live list of sessions that
currently have an open webhook (an active watcher), and every connected client is
told to list the tools again when that set changes (MCP-21, TRS-07).
"""
from aidc_mcp import audit, server
from aidc_mcp.service import state as ss
from aidc_mcp.tearstools import base, descriptions


class _StubTask:
    """Stands in for an asyncio.Task in ss.session_watchers (only the key matters)."""

    def cancel(self):
        pass


def _reset():
    ss.session_watchers.clear()


def _listed(face, name):
    return next(t for t in face.listing() if t.name == name)


class TestWatchingSuffix:
    def test_empty_when_no_watchers(self):
        _reset()
        s = descriptions.watching_suffix()
        assert "No session is being watched" in s
        assert "OPEN WEBHOOKS" not in s

    def test_lists_watched_sessions_sorted(self):
        _reset()
        ss.session_watchers["beta"] = _StubTask()
        ss.session_watchers["alpha"] = _StubTask()
        s = descriptions.watching_suffix()
        assert "OPEN WEBHOOKS" in s
        # sorted, both present
        assert s.index("alpha") < s.index("beta")
        _reset()


class TestLiveDescriptions:
    """The face lists each session tool with the watched sessions as they are now."""

    def test_appends_empty_state_then_session_list(self):
        _reset()
        face = server.Face()
        d0 = _listed(face, "session_send").description
        assert d0.startswith("The place for anything long")
        assert "No session is being watched" in d0

        ss.session_watchers["myproj"] = _StubTask()
        d1 = _listed(face, "session_send").description
        assert "myproj" in d1 and "OPEN WEBHOOKS" in d1
        assert d1.startswith("The place for anything long")
        _reset()

    def test_listing_again_does_not_double_the_base(self):
        _reset()
        face = server.Face()
        ss.session_watchers["a"] = _StubTask()
        d1 = _listed(face, "session_send").description
        d2 = _listed(face, "session_send").description
        assert d1 == d2
        assert d2.count("The place for anything long") == 1
        _reset()

    def test_reflects_removal(self):
        _reset()
        face = server.Face()
        ss.session_watchers["gone"] = _StubTask()
        assert "gone" in _listed(face, "session_send").description
        ss.session_watchers.clear()
        d = _listed(face, "session_send").description
        assert "gone" not in d and "No session is being watched" in d
        _reset()

    def test_exactly_the_session_aware_tools_carry_the_list(self):
        _reset()
        ss.session_watchers["proj"] = _StubTask()
        aware = {t.name for t in server.Face().listing() if "OPEN WEBHOOKS" in t.description}
        assert aware == {"session_send", "session_invoke", "session_invoke_async"}
        assert all(isinstance(t, base.SessionAwareTool) == (t.local_name in aware)
                   for t in server.Face().tools)
        _reset()


class TestRoutingCues:
    """Pin the cross-references that route 'ask the session's agent a question' to
    session_send. Twice now the orchestrator self-served via session_exec/file_get
    instead of delegating to the resident agent; these cues are the guard."""

    def _descs(self):
        return {t.name: t.description.lower() for t in server.Face(include_create=True).listing()}

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


class TestAnnounce:
    async def test_announcing_tells_every_connected_client(self, monkeypatch):
        face = server.Face()
        told = []

        async def notify():
            told.append(True)
        monkeypatch.setattr(face.server, "notify_tools_changed", notify)
        await face.announce()
        assert told == [True]

    async def test_a_failed_notify_is_logged_and_does_not_fail_the_call(self, monkeypatch):
        face = server.Face()

        async def notify():
            raise RuntimeError("stream closed")
        monkeypatch.setattr(face.server, "notify_tools_changed", notify)
        await face.announce()
        assert "tool_list_changed_notify_failed" in audit._AUDIT_PATH.read_text()

    def test_the_tools_that_change_the_watch_list_announce_through_the_face(self):
        face = server.Face()
        for tool in face.tools:
            assert tool.hooks.announce == face.announce, tool.local_name
