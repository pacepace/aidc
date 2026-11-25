"""Capturing log_event in the tests.

Every module logs through the one binding, `audit.log_event` (none imports log_event
by name), so patching it there catches every event, whichever module logs it: tools,
the service, auth and session_facts alike.
"""
import contextlib
from unittest.mock import MagicMock, patch

from aidc_mcp import audit


def patch_log_event(monkeypatch, fn):
    """Route every log_event to `fn` for the rest of the test."""
    monkeypatch.setattr(audit, "log_event", fn)


@contextlib.contextmanager
def log_event_patched(side_effect=None):
    """One MagicMock standing in for every log_event."""
    mock = MagicMock(side_effect=side_effect)
    with patch.object(audit, "log_event", mock):
        yield mock
