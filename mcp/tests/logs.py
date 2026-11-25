"""Capturing log_event in the tests.

tools.py and every service module import log_event by name, so each holds its own
binding: patching one module's would miss events the code under test logs from another.
These patch them all at once.
"""
import contextlib
import importlib
import pkgutil
from unittest.mock import MagicMock, patch

import aidc_mcp.service as service
from aidc_mcp import tools


def _logging_modules():
    modules = [tools] + [importlib.import_module(f"aidc_mcp.service.{m.name}")
                         for m in pkgutil.iter_modules(service.__path__)]
    return [m for m in modules if hasattr(m, "log_event")]


def patch_log_event(monkeypatch, fn):
    """Route every log_event of tools and the service to `fn` for the rest of the test."""
    for module in _logging_modules():
        monkeypatch.setattr(module, "log_event", fn)


@contextlib.contextmanager
def log_event_patched(side_effect=None):
    """One MagicMock standing in for every log_event of tools and the service."""
    mock = MagicMock(side_effect=side_effect)
    with contextlib.ExitStack() as stack:
        for module in _logging_modules():
            stack.enter_context(patch.object(module, "log_event", mock))
        yield mock
