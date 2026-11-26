import asyncio

import pytest

from aidc_mcp import headless, session_facts
from aidc_mcp import transcript as ts
from aidc_mcp.service import state as ss
from aidc_mcp.service import turns as tn


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
    ss.invokes_in_flight.clear()
    yield
    headless._runs.clear()
    ss.invokes_in_flight.clear()


@pytest.fixture
def idle_session(monkeypatch):
    """A session whose coding agent is not running: _session_state without docker."""
    async def state(container, name):
        return tn.SessionState(False, None, tn.TURN_IDLE, "claude_not_running")
    monkeypatch.setattr(tn, "session_state", state)


@pytest.fixture(autouse=True)
def _no_operator_config(tmp_path, monkeypatch):
    """session_create reads the backend from $HOME/.config/aidc/config.yaml, as the CLI
    does. No test reads the developer's own config: a `backend: kubernetes` there would
    change every create a test makes."""
    home = tmp_path / "operator-home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))


@pytest.fixture(autouse=True)
def _isolate_audit_log(tmp_path, monkeypatch):
    """Redirect the MCP audit log to a temp file so tests exercise real
    log_event() without touching /var/log/aidc-mcp (unwritable in CI/dev).
    log_event reads the module global at call time, so patching it here works."""
    monkeypatch.setattr("aidc_mcp.audit._AUDIT_PATH", tmp_path / "access.log")
    # Same for the watcher-state dir, which the send-queue dead-letter writer
    # resolves at call time.
    monkeypatch.setattr(ss, "WATCHER_STATE_DIR", tmp_path / "watcher-state")
    yield
    # each test's state stores are its own: closed when it ends, so their file locks go
    from aidc_mcp import store
    store.close_all(within=[tmp_path])


@pytest.fixture(autouse=True)
async def clean_session_watchers():
    """Reset all per-session module state between tests so nothing leaks across
    them: watcher tasks, pending-send queues and their drainers, transcript settle
    state and send locks."""
    def _reset():
        ss.session_watchers.clear()
        ss.pending_sends.clear()
        ss.pending_drainers.clear()
        ss.settle_state.clear()
        ss.session_send_locks.clear()
        ss.sent_awaiting_echo.clear()
        ss.working_indicator_seen.clear()
        ss.unanswered_polls.clear()
        ss.reported_interrupts.clear()
        ss.last_free_verdict.clear()
        ss.last_screen_raw.clear()
        ss.unsubmitted_paste.clear()
        ss.waiting_notice_shown.clear()
        ss.drainer_failures.clear()
        ss.queue_loaded.clear()
        ss.session_instances.clear()
        ts._parsed.clear()
        ts._newest_ts.clear()

    _reset()
    yield
    for task in [*ss.session_watchers.values(), *ss.pending_drainers.values()]:
        task.cancel()
        try:
            await asyncio.gather(task, return_exceptions=True)
        except Exception:
            pass
    _reset()
