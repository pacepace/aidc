import asyncio

import pytest

from aidc_mcp import headless, session_facts, tools
from aidc_mcp import transcript as ts


async def no_docker(*args, timeout=20.0):
    """What docker says about a session that has nothing to tell: no taint flag, no
    events, no audit mount, no dev container. A test that needs a fact patches
    session_facts.run_docker itself."""
    return session_facts.DockerResult(1, b"", b"cat: No such file or directory")


@pytest.fixture(autouse=True)
def _no_real_docker_for_facts(monkeypatch):
    """session_facts asks docker for a session's taint, audit dir and repository on
    most calls. No test reaches a real docker through it."""
    monkeypatch.setattr(session_facts, "run_docker", no_docker)


async def no_headless_processes(container):
    """What a session's container shows when no headless claude runs in it."""
    return []


@pytest.fixture(autouse=True)
def _no_real_docker_for_headless(monkeypatch):
    """session_status, session_invoke and the invoke guard look for `claude --print`
    processes in the container. No test reaches a real docker through it, and none
    sees another test's runs."""
    monkeypatch.setattr(headless, "container_runs", no_headless_processes)
    headless._runs.clear()
    tools._invokes_in_flight.clear()
    yield
    headless._runs.clear()
    tools._invokes_in_flight.clear()


@pytest.fixture
def idle_session(monkeypatch):
    """A session whose coding agent is not running: _session_state without docker."""
    async def state(container, name):
        return tools.SessionState(False, None, tools.TURN_IDLE, "claude_not_running")
    monkeypatch.setattr(tools, "_session_state", state)


@pytest.fixture(autouse=True)
def _isolate_audit_log(tmp_path, monkeypatch):
    """Redirect the MCP audit log to a temp file so tests exercise real
    log_event() without touching /var/log/aidc-mcp (unwritable in CI/dev).
    log_event reads the module global at call time, so patching it here works."""
    monkeypatch.setattr("aidc_mcp.audit._AUDIT_PATH", tmp_path / "access.log")
    # Same for the watcher-state dir, which the send-queue dead-letter writer
    # resolves at call time.
    monkeypatch.setattr(tools, "_WATCHER_STATE_DIR", tmp_path / "watcher-state")


@pytest.fixture(autouse=True)
async def clean_session_watchers():
    """Reset all per-session module state between tests so nothing leaks across
    them: watcher tasks, pending-send queues and their drainers, transcript settle
    state, send locks, and the captured tool-description bases."""
    def _reset():
        tools._session_watchers.clear()
        tools._pending_sends.clear()
        tools._pending_drainers.clear()
        tools._settle_state.clear()
        tools._session_send_locks.clear()
        tools._tool_base_desc.clear()
        tools._sent_awaiting_echo.clear()
        tools._working_indicator_seen.clear()
        tools._unanswered_polls.clear()
        tools._reported_interrupts.clear()
        tools._last_free_verdict.clear()
        tools._last_screen_raw.clear()
        tools._unsubmitted_paste.clear()
        tools._waiting_notice_shown.clear()
        tools._drainer_failures.clear()
        tools._queue_loaded.clear()
        tools._session_instances.clear()
        ts._parsed.clear()
        ts._newest_ts.clear()

    _reset()
    yield
    for task in [*tools._session_watchers.values(), *tools._pending_drainers.values()]:
        task.cancel()
        try:
            await asyncio.gather(task, return_exceptions=True)
        except Exception:
            pass
    _reset()
