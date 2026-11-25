"""The session's tmux: pane captures, the foreground command, keys and pastes.

No MCP types here (test_service_boundary): the tools in tools.py adapt it.
"""

from __future__ import annotations

import asyncio

from aidc_mcp import backend

SESSION_WINDOW = "claude"


# Foreground pane commands that mean Claude is NOT running (a bare shell / idle).
_SHELL_COMMANDS = frozenset({"bash", "sh", "zsh", "fish", "dash", ""})


async def tmux_exec(container: str, args: list[str]) -> int:
    """Run a tmux command inside the container as vscode user. Returns exit code."""
    proc = await asyncio.create_subprocess_exec(
        *backend.exec_argv(container, ["tmux", *args], user="vscode"),
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    return await proc.wait()


async def capture_screen(container: str, window: str) -> str:
    """The visible pane with its escape sequences (-e), wrapped lines joined (-J)."""
    proc = await asyncio.create_subprocess_exec(
        *backend.exec_argv(container, ["tmux", "capture-pane", "-t", f"main:{window}", "-p",
                                       "-e", "-J"], user="vscode"),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    return stdout.decode("utf-8", errors="replace")


async def _pane_current_command(container: str, window: str) -> str:
    """Return the current foreground command name running in a tmux pane."""
    proc = await asyncio.create_subprocess_exec(
        *backend.exec_argv(container, ["tmux", "display-message", "-t", f"main:{window}", "-p",
                                       "#{pane_current_command}"], user="vscode"),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    return stdout.decode().strip().lower()


async def _window_exists(container: str, window: str) -> bool:
    """Return True if a tmux window with the given name exists in the main session."""
    proc = await asyncio.create_subprocess_exec(
        *backend.exec_argv(container, ["tmux", "list-windows", "-t", "main", "-F",
                                       "#{window_name}"], user="vscode"),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate()
    return window in stdout.decode().splitlines()


async def is_claude_running(container: str) -> bool:
    """Return True if Claude is the foreground process in the claude tmux window."""
    if not await _window_exists(container, SESSION_WINDOW):
        return False
    cmd = await _pane_current_command(container, SESSION_WINDOW)
    return cmd not in _SHELL_COMMANDS


async def load_and_paste(container: str, text: str, window: str) -> bool:
    """Load text into a tmux paste buffer and paste it into the window. Returns True on success."""
    proc = await asyncio.create_subprocess_exec(
        *backend.exec_argv(container, ["tmux", "load-buffer", "-b", "aidc-send", "-"],
                           user="vscode", stdin=True),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    await proc.communicate(text.encode("utf-8"))
    if proc.returncode != 0:
        return False
    rc = await tmux_exec(container, ["paste-buffer", "-b", "aidc-send", "-t", f"main:{window}"])
    return rc == 0
