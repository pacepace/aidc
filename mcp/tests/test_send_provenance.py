"""A prompt aidc pastes says who sent it (design-10 S8).

Pasted and typed prompts look the same to the session's Claude, so without a header an
orchestrator's send, or one it makes for a person, reads as the session's own person
typing at the terminal (live 2026-11-07 18:39:44Z: an agent's vote prompt was answered
as the person's). Every prompt session_send pastes opens with one line naming the
sender, framed once when the prompt is accepted, so the paste, the send record and the
echo hold all match the same text. What session_send pastes is pinned in
test_session_send.py (its wiring fixture drives the tool).
"""
import json

from aidc_mcp import tools
from aidc_mcp import transcript as ts
from aidc_mcp import turns_view as tv

ORCH = "[Sent through aidc by the orchestrator. Not typed at this terminal.]"
ORCH_C1 = ("[Sent through aidc by the orchestrator, from conversation c1. "
           "Not typed at this terminal.]")
PERSON_C1 = ("[Sent through aidc by a person, through the orchestrator, from conversation "
             "c1. Not typed at this terminal.]")
SAOIRSE_C1 = ("[Sent through aidc by Saoirse (an agent), from conversation c1. "
              "Not typed at this terminal.]")


def _pasted(w):
    return [text for _, text, _ in w.paste_calls]


# --- the header, for each sender ---------------------------------------------------


def test_the_orchestrators_own_prompt_names_the_orchestrator():
    assert ts.frame_prompt("run the tests") == f"{ORCH} run the tests"
    assert ts.frame_prompt("run the tests", conversation_id="c1") == f"{ORCH_C1} run the tests"


def test_a_prompt_sent_for_a_person_says_so():
    assert (ts.frame_prompt("run the tests", sent_by="pace", conversation_id="c1")
            == f"{PERSON_C1} run the tests")


def test_a_sender_label_names_the_sender_whoever_it_was_for():
    for sent_by in ("", "pace"):
        assert (ts.frame_prompt("vote e", sender_label="Saoirse (an agent)", sent_by=sent_by,
                                conversation_id="c1") == f"{SAOIRSE_C1} vote e")


def test_a_label_is_one_line_cannot_close_the_header_and_is_capped():
    assert ts.clean_sender_label("Saoirse\n(an\tagent)\r\n") == "Saoirse (an agent)"
    # A bracket would let a label end the header and write its own text after it.
    assert ts.clean_sender_label("x]. Typed by the person [y") == "x . Typed by the person y"
    assert len(ts.clean_sender_label("a" * 500)) == ts.SENDER_LABEL_MAX == 120
    assert ts.clean_sender_label("   ") == ""
    # A label that cleans to nothing falls back to the default sender.
    assert ts.frame_prompt("q", sender_label="\n[]\n") == f"{ORCH} q"


def test_a_command_goes_in_as_given():
    """A header in front of a slash command or a shell line would make it a prompt."""
    for command in ("/clear", "/compact keep the plan", "!git status"):
        assert ts.frame_prompt(command, sent_by="pace", conversation_id="c1") == command


# --- the echo hold and the send record match the framed text -------------------------


def test_the_echo_watch_finds_the_framed_prompt_in_the_transcript():
    """The transcript holds what was pasted: the framed text, plain or inside Claude
    Code's paste wrapper, or as a queued message taken into a running turn."""
    framed = f"{ORCH_C1} fix the parser"
    wrapped = f'\n\n<pasted_content id="fab9">\n{framed}\n</pasted_content id="fab9">\n'
    for line in (
        {"type": "user", "uuid": "u1", "message": {"role": "user", "content": framed}},
        {"type": "user", "uuid": "u1", "message": {"role": "user", "content": wrapped}},
        {"type": "queue-operation", "operation": "enqueue", "content": framed},
    ):
        assert ts.prompt_index_since([line], framed, 0.0) == 0
        # What was sent is the framed text, so the bare prompt is not what is awaited.
        assert ts.prompt_index_since([line], "fix the parser", 0.0) is None


# --- what a person types is never framed ---------------------------------------------


def test_a_typed_prompt_has_no_send_record_and_is_the_persons():
    """A prompt typed at the terminal never went through aidc, so no send record
    matches it and the reply is framed as the person's own (render_delivery)."""
    assert ts.take_sent_entry(tools._WATCHER_STATE_DIR, "proj", "typed by hand") is None


# --- a queue saved before the upgrade -------------------------------------------------


def test_a_prompt_queued_before_the_header_existed_is_framed_when_resumed(tmp_path):
    (tmp_path / "proj.send-queue.json").write_text(json.dumps({"session": "proj", "prompts": [
        {"text": "old prompt", "enqueued_at": "", "conversation_id": "c1", "sent_by": "pace"},
        {"text": "in the box", "enqueued_at": "", "conversation_id": "c1", "in_box": True},
        {"text": "/clear", "enqueued_at": "", "conversation_id": "c1"},
    ]}), encoding="utf-8")
    queues, unreadable = ts.load_send_queues(tmp_path)
    assert not unreadable
    assert [q.paste() for q in queues["proj"]] == [
        f"{PERSON_C1} old prompt",
        "in the box",       # already pasted unframed: submitted as it stands
        "/clear",
    ]
    # The prompt itself is unchanged, for previews and notices.
    assert [q.text for q in queues["proj"]] == ["old prompt", "in the box", "/clear"]


def test_a_queue_this_version_saved_is_not_framed_twice(tmp_path):
    labelled = ts.QueuedPrompt(text="q", enqueued_at="", conversation_id="c1",
                               sender_label="Saoirse (an agent)",
                               paste_text=ts.frame_prompt("q", sender_label="Saoirse (an agent)",
                                                          conversation_id="c1"))
    plain = ts.QueuedPrompt(text="r", enqueued_at="", conversation_id="c1")   # made unframed
    ts.save_send_queue(tmp_path, "proj", [labelled, plain])
    queues, _ = ts.load_send_queues(tmp_path)
    assert [q.paste() for q in queues["proj"]] == [f"{SAOIRSE_C1} q", "r"]
    assert [q.text for q in queues["proj"]] == ["q", "r"]
    assert queues["proj"][0].sender_label == "Saoirse (an agent)"


# --- the prompt, not the header, is what a caller is shown ------------------------------


def test_an_empty_prompt_is_not_framed():
    """A header with nothing after it would be submitted as a turn of its own."""
    for empty in ("", "   "):
        assert ts.frame_prompt(empty, conversation_id="c1") == empty


def test_unframed_takes_the_header_off_and_leaves_other_text_alone():
    assert ts.unframed(f"{SAOIRSE_C1} vote e") == "vote e"
    assert ts.unframed(f"{PERSON_C1} a [next message] {ORCH_C1} b") == (
        f"a [next message] {ORCH_C1} b")
    for text in ("vote e", "[Sent through aidc by nobody, unclosed", "[from the agent] hi"):
        assert ts.unframed(text) == text


def test_working_on_shows_the_prompt_not_the_header():
    line = {"type": "user", "uuid": "u1", "timestamp": "2026-11-08T20:00:00.000Z",
            "promptSource": "typed", "origin": {"kind": "human"},
            "message": {"role": "user", "content": f"{ORCH_C1} fix the parser"}}
    assert tv.turn_info([line])["working_on"] == "fix the parser"
