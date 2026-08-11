import asyncio

import pytest

from aidc_mcp import tools


@pytest.fixture(autouse=True)
def _isolate_audit_log(tmp_path, monkeypatch):
    """Redirect the MCP audit log to a temp file so tests exercise real
    log_event() without touching /var/log/aidc-mcp (unwritable in CI/dev).
    log_event reads the module global at call time, so patching it here works."""
    monkeypatch.setattr("aidc_mcp.audit._AUDIT_PATH", tmp_path / "access.log")


@pytest.fixture(autouse=True)
async def clean_session_watchers():
    """Reset all per-session module state between tests so nothing leaks across
    them: watcher tasks, transcript settle state, send locks, and the captured
    tool-description bases."""
    def _reset():
        tools._session_watchers.clear()
        tools._settle_state.clear()
        tools._session_send_locks.clear()
        tools._tool_base_desc.clear()

    _reset()
    yield
    for task in list(tools._session_watchers.values()):
        task.cancel()
        try:
            await asyncio.gather(task, return_exceptions=True)
        except Exception:
            pass
    _reset()
