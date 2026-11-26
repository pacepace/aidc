"""Text the tools' descriptions share: the parameter descriptions several tools use, and
the live tail of the session tools' descriptions naming the watched sessions (MCP-21).

Trigger- and usage-oriented, so smaller models supply the arguments correctly; above all,
never invent conversation_id. Carried over word for word from 1.x (MCP-22, TRS-11).
"""

from __future__ import annotations

from aidc_mcp import transcript as ts
from aidc_mcp.service import state as ss

NAME_DESC = (
    "The aidc session to use. Pick a running session (call session_list) or one of the "
    "open-webhook sessions named in this tool's description."
)
CONV_ID_DESC = (
    "Injected automatically by the orchestrator. Leave this unset — do NOT supply, invent, or "
    "reason about it."
)
PROMPT_DESC = "The prompt / message text to send to the session."
SENT_BY_DESC = (
    "Set by the orchestrator when the prompt is a person's, not its own: who sent it. "
    "Leave this unset."
)
SENDER_LABEL_DESC = (
    "Optional: who is sending, as the session should read it (one line, at most "
    f"{ts.SENDER_LABEL_MAX} characters), e.g. \"Saoirse (an agent)\". aidc opens every "
    "prompt it pastes with a line naming the sender, so the session never reads it as "
    "typed at its terminal; without this it names \"the orchestrator\", or \"a person, "
    "through the orchestrator\" when sent_by is set."
)
DELIVER_DESC = (
    'What to do if the agent is in the middle of a turn. "queue" (the default): hold the '
    "prompt and paste it when the turn ends; its reply comes on its own. \"join\": paste it "
    "now, and the agent takes it into the turn it is working on at its next step; the reply "
    "is part of that turn's final answer. With the agent idle, both send at once."
)


def watching_suffix() -> str:
    """The live tail appended to session-tool descriptions: which sessions have
    an open webhook right now."""
    names = sorted(ss.session_watchers.keys())
    if names:
        return (
            "\n\nOPEN WEBHOOKS — these sessions stream their responses back to this "
            "conversation automatically; pass one of these as `name`: "
            + ", ".join(names)
            + "."
        )
    return (
        "\n\nNo session is being watched yet. session_send auto-starts a "
        "webhook for the `name` you pass (session_watch starts one explicitly)."
    )


#: the tools whose descriptions end with watching_suffix()
SESSION_AWARE_TOOLS = ("session_send", "session_invoke", "session_invoke_async")
