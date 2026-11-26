"""aidc's tools as 3tears TearsTools (TRS-10, TRS-11, TRS-15, MCP-22).

Every published tool is one TearsTool over the service, named `aidc.<tool>` on the mesh,
with its 1.x description and parameter descriptions word for word: an orchestrator's model
reads them to choose a tool and fill its arguments, so a changed word changes what it does.
The 1.x list is kept as `tests/fixtures/published-tools-1x.json` (the server's list when
2.0 began), since `mcp/published-tools.json` is regenerated from these tools.

The tools are called here through `run`, as every face calls them, against the service
with docker stubbed."""
import json
import pathlib
import subprocess

import pytest
from threetears.tool_contract import TearsTool, ToolResult
from threetears.tool_schema import self_contained_input_schema

from aidc_mcp import tearstools
from aidc_mcp.service import common as com
from aidc_mcp.service import delivery as dlv
from aidc_mcp.service import sessions as ses
from aidc_mcp.tearstools import ToolHooks, build_tools, envelope_result

V1 = json.loads((pathlib.Path(__file__).parent / "fixtures" / "published-tools-1x.json")
                .read_text(encoding="utf-8"))
V1_BY_NAME = {t["name"]: t for t in V1}


def _tool(name, hooks=None):
    return next(t for t in build_tools(hooks) if t.local_name == name)


def _envelope(result):
    assert isinstance(result, ToolResult)
    return json.loads(result.content)


# --- one TearsTool per published tool ---------------------------------------------

def test_every_published_tool_has_exactly_one_tears_tool():
    names = [t.local_name for t in build_tools()]
    assert sorted(names) == sorted(V1_BY_NAME)
    assert len(names) == len(set(names))
    assert all(isinstance(t, TearsTool) for t in build_tools())


def test_session_create_is_left_out_when_the_face_does_not_offer_it():
    # MCP-38: the face decides; the tool set without it is the rest unchanged
    names = {t.local_name for t in build_tools(include_create=False)}
    assert names == set(V1_BY_NAME) - {"session_create"}


def test_the_withdrawn_tools_have_no_tears_tool():
    assert not {t.local_name for t in build_tools()} & {"session_kill", "session_run", "taint_mark"}


def test_each_tool_is_named_aidc_dot_its_local_name_on_the_mesh():
    # TRS-15: the mesh has one registry and no server namespace
    for tool in build_tools():
        assert tool.mcp_name() == f"aidc.{tool.local_name}"
        assert tool.mcp_schema().name == tool.mcp_name()


def test_each_tool_declares_the_mcp_face():
    # the bridge refuses a tool that does not
    assert all(t.face_mcp for t in build_tools())


# --- descriptions and schemas carried over (TRS-11, MCP-22) -------------------------

# The descriptions 2.0 extends, each with the one change made to 1.x's words and why: an
# orchestrator reads a field the description names, and on a new backend the field took a new
# form. Every other word stays 1.x's (TRS-11), held exactly.
EXTENDED_IN_2_0 = {
    "audit_get": ("audit_dir (where the session's audit trail is on the host)",
                  "audit_dir (where the session's audit trail is on the host; on Kubernetes\n"
                  "`pvc:<namespace>/<claim>`, its volume claim)"),
    # a cluster session's Claude account (K8S-16/17): an orchestrator must see that no account
    # can be used rather than a session that silently stops answering (main, 2026-11-26)
    "session_status": ("watched_conversation_id (where its replies are delivered),\n",
                       "watched_conversation_id (where its replies are delivered),\n"
                       "claude_account (a cluster session whose Claude login is your account broker's:\n"
                       "{account, notice, at}; notice says what needs you, e.g. that no account can be\n"
                       "used; null otherwise),\n"),
}


@pytest.mark.parametrize("name", sorted(V1_BY_NAME))
def test_the_description_is_the_1x_description_word_for_word(name):
    # with no session watched, as the 1.x list was generated
    expected = V1_BY_NAME[name]["description"]
    if name in EXTENDED_IN_2_0:
        old, new = EXTENDED_IN_2_0[name]
        assert expected.count(old) == 1
        expected = expected.replace(old, new)
    assert _tool(name).mcp_schema().description == expected


@pytest.mark.parametrize("name", sorted(V1_BY_NAME))
def test_every_parameter_description_is_the_1x_one_word_for_word(name):
    ours = _tool(name).mcp_schema().input_schema["properties"]
    theirs = V1_BY_NAME[name]["input_schema"]["properties"]
    assert set(ours) == set(theirs)
    for param, spec in theirs.items():
        assert ours[param].get("description") == spec.get("description"), param


def _nullable_in_1x(schema):
    return {n for n, spec in schema["properties"].items()
            if {"type": "null"} in spec.get("anyOf", [])}


@pytest.mark.parametrize("name", sorted(V1_BY_NAME))
def test_the_schema_is_the_1x_schema_made_self_contained(name):
    # tool-schema's flattening, with null still allowed where 1.x allowed it
    v1 = V1_BY_NAME[name]["input_schema"]
    expected = self_contained_input_schema(v1, tool_name=name)
    for param in _nullable_in_1x(v1):
        expected["properties"][param]["type"] = [expected["properties"][param]["type"], "null"]
    assert _tool(name).mcp_schema().input_schema == expected


def test_every_argument_1x_let_be_null_may_still_be_null():
    # a null sent_by or conversation_id refused before the tool runs would be a prompt
    # silently not sent; the listing keeps null legal for exactly those arguments
    seen = 0
    for name, tool in V1_BY_NAME.items():
        ours = _tool(name).mcp_schema().input_schema["properties"]
        for param, spec in ours.items():
            nullable = isinstance(spec.get("type"), list) and "null" in spec["type"]
            assert nullable is (param in _nullable_in_1x(tool["input_schema"])), (name, param)
            seen += nullable
    assert seen >= 10


async def test_a_null_optional_argument_reaches_the_service_as_not_given(monkeypatch):
    seen = {}

    async def audit_get(name, since=None, kind=None):
        seen.update(since=since, kind=kind)
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "audit_get", audit_get)
    result = await _tool("audit_get").run(name="proj", since=None, kind=None)
    assert result.success and seen == {"since": None, "kind": None}


def test_no_schema_has_a_ref_or_defs():
    text = json.dumps([t.mcp_schema().input_schema for t in build_tools()])
    assert "$ref" not in text and "$defs" not in text


async def test_the_session_tools_descriptions_name_the_watched_sessions():
    # MCP-21: read live on every listing, so a new webhook shows up without a restart
    import asyncio

    from aidc_mcp.service import state as ss
    ss.session_watchers["alpha"] = asyncio.get_running_loop().create_future()
    for name in ("session_send", "session_invoke", "session_invoke_async"):
        assert "OPEN WEBHOOKS" in _tool(name).description()
        assert "alpha" in _tool(name).description()
    assert "alpha" not in _tool("session_status").description()


# --- the envelope as the ToolResult (TRS-10) ----------------------------------------

def test_an_ok_envelope_is_a_successful_result_holding_it_as_json():
    result = envelope_result(com.envelope_ok({"x": 1}))
    assert result.success is True and json.loads(result.content) == {"ok": True, "data": {"x": 1}}
    assert result.error_code is None


def test_a_failed_envelope_carries_its_aidc_code_in_the_metadata_not_as_a_platform_code():
    result = envelope_result(com.envelope_err("no", code="tainted"))
    assert result.success is False
    assert json.loads(result.content) == {"ok": False, "error": "no", "error_code": "tainted"}
    assert result.metadata == {"error_code": "tainted"}
    assert result.error == "no"
    # ToolResult's own five codes mean other things; none is set for an aidc refusal
    assert result.error_code is None


async def test_run_calls_the_service_and_returns_its_envelope(monkeypatch):
    async def status(name):
        return com.envelope_ok({"session": name, "working": False})
    monkeypatch.setattr(ses, "status", status)
    result = await _tool("session_status").run(name="proj")
    assert result.success is True
    assert _envelope(result) == {"ok": True, "data": {"session": "proj", "working": False}}


async def test_a_service_refusal_comes_back_as_a_failed_result_with_its_code(monkeypatch):
    async def status(name):
        return com.envelope_err("There is no session named 'ghost'.", code="no_such_session")
    monkeypatch.setattr(ses, "status", status)
    result = await _tool("session_status").run(name="ghost")
    assert result.success is False and result.metadata == {"error_code": "no_such_session"}
    assert _envelope(result)["error_code"] == "no_such_session"


async def test_defaults_are_filled_and_unknown_arguments_ignored_as_in_1x(monkeypatch):
    seen = {}

    async def transcript(name, last_n=5, since_uuid=""):
        seen.update(name=name, last_n=last_n, since_uuid=since_uuid)
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "transcript", transcript)
    result = await _tool("session_transcript").run(name="proj", last_n="3", stray=1)
    assert result.success is True
    assert seen == {"name": "proj", "last_n": 3, "since_uuid": ""}


async def test_an_argument_that_cannot_be_read_is_refused_before_the_service_runs(monkeypatch):
    async def status(name):
        raise AssertionError("the service must not run")
    monkeypatch.setattr(ses, "status", status)
    result = await _tool("session_status").run()
    assert result.success is False and result.metadata == {"error_code": "invalid_argument"}
    assert "name" in _envelope(result)["error"]


async def test_a_blocking_service_call_runs_off_the_event_loop(monkeypatch):
    import threading
    loop_thread = threading.get_ident()
    ran_on = []

    def exec_command(name, cmd, timeout_seconds=60):
        ran_on.append(threading.get_ident())
        return com.envelope_ok({"exit_code": 0})
    monkeypatch.setattr(ses, "exec_command", exec_command)
    result = await _tool("session_exec").run(name="proj", cmd="true")
    assert result.success is True and ran_on and ran_on[0] != loop_thread


# --- what a tool tells its caller while it runs ---------------------------------------

class _Ctx:
    """A real call context whose channels record what the tool sends."""

    def __init__(self, progress_token="tok"):
        from threetears.mcp import CallContext
        self.logged, self.progress = [], []

        async def log(level, data, logger):
            self.logged.append((level, data))

        async def progress(value, total, message):
            self.progress.append((value, message))
        self.ctx = CallContext(tool_name="t", progress_token=progress_token,
                               progress_sender=progress, log_sender=log)


async def test_create_reports_each_phase_to_the_caller_as_a_log_line(monkeypatch):
    async def create(*, progress, **kwargs):
        await progress("building")
        await progress("starting")
        return com.envelope_ok({"name": kwargs["name"]})
    monkeypatch.setattr(ses, "create", create)
    ctx = _Ctx()
    result = await _tool("session_create").execute(ctx.ctx, name="proj", repo="/r")
    assert result.success is True
    assert ctx.logged == [("info", "building"), ("info", "starting")]
    # TRS-04: each phase is also a progress notification, counting up
    assert ctx.progress == [(1, "building"), (2, "starting")]


async def test_without_a_progress_token_the_phases_are_still_logged(monkeypatch):
    async def create(*, progress, **kwargs):
        await progress("building")
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "create", create)
    ctx = _Ctx(progress_token=None)
    await _tool("session_create").execute(ctx.ctx, name="proj", repo="/r")
    assert ctx.logged == [("info", "building")] and ctx.progress == []


async def test_without_a_call_context_the_service_gets_no_progress_hook(monkeypatch):
    seen = {}

    async def create(*, progress, **kwargs):
        seen["progress"] = progress
        return com.envelope_ok({})
    monkeypatch.setattr(ses, "create", create)
    await _tool("session_create").run(name="proj", repo="/r")
    assert seen["progress"] is None


async def test_watching_a_session_announces_the_change_through_the_faces_hook(monkeypatch):
    announced = []

    async def announce():
        announced.append(True)

    async def watch(*, name, conversation_id, announce):
        await announce()
        return com.envelope_ok({"session": name})
    monkeypatch.setattr(dlv, "watch", watch)
    result = await _tool("session_watch", ToolHooks(announce=announce)).run(name="proj")
    assert result.success is True and announced == [True]


# --- file_put overwrites (#76) --------------------------------------------------------

def _run_file_put_locally(monkeypatch):
    """subprocess.run for file_put's `docker exec ... bash -c SCRIPT file_put PATH MODE`,
    running the script here with bash, as the session's shell would."""
    real_run = subprocess.run

    def run(argv, **kwargs):
        start = argv.index("bash")
        return real_run(argv[start:], **kwargs)
    monkeypatch.setattr(subprocess, "run", run)


async def test_file_put_overwrites_an_existing_file(monkeypatch, tmp_path):
    # 1.x wrote with `install -m MODE /dev/stdin PATH`, which the uutils coreutils of the
    # session image refuse on an existing file ("No such file or directory")
    _run_file_put_locally(monkeypatch)
    where = tmp_path / "repo"
    where.mkdir()
    target = where / "a.txt"
    tool = _tool("file_put")
    first = await tool.run(name="proj", path=str(target), content="one")
    second = await tool.run(name="proj", path=str(target), content="two", mode="0600")
    assert first.success and second.success, (first.content, second.content)
    assert target.read_text() == "two"
    assert oct(target.stat().st_mode & 0o777) == "0o600"
    assert [p.name for p in where.iterdir()] == ["a.txt"]  # no temporary file left


async def test_file_put_into_a_missing_directory_fails_and_says_why(monkeypatch, tmp_path):
    _run_file_put_locally(monkeypatch)
    result = await _tool("file_put").run(name="proj", path=str(tmp_path / "no" / "f"),
                                         content="x")
    assert result.success is False and result.metadata == {"error_code": "command_failed"}
    assert "No such file or directory" in _envelope(result)["error"]


async def test_file_put_takes_a_path_with_quotes_spaces_and_semicolons_as_data(monkeypatch,
                                                                              tmp_path):
    # the path reaches bash as an argument, never as script text: written, nothing run
    _run_file_put_locally(monkeypatch)
    monkeypatch.chdir(tmp_path)          # where a `touch ran` would land
    canary = tmp_path / "ran"
    target = tmp_path / "it's a; touch ran #.txt"
    result = await _tool("file_put").run(name="proj", path=str(target), content="data")
    assert result.success, result.content
    assert target.read_text() == "data"
    assert not canary.exists()


def test_the_package_exports_the_tool_set():
    assert len(tearstools.TOOL_CLASSES) == len(V1)


def test_file_put_does_not_write_with_install():
    # the host's GNU install overwrites, so the test above passes there either way; the
    # session image's uutils install does not (measured in ubuntu:26.04, uutils 0.10.0)
    assert "install" not in ses.FILE_PUT_SCRIPT.split()


def test_prepare_arguments_turns_whole_numbers_in_text_into_numbers_only_for_integers():
    queue_cancel = _tool("session_queue_cancel")   # position: integer or null
    assert queue_cancel.prepare_arguments({"name": "7", "position": "-2"}) == {
        "name": "7", "position": -2}
    assert queue_cancel.prepare_arguments({"position": "2.0"}) == {"position": "2.0"}
    assert queue_cancel.prepare_arguments({"position": None}) == {"position": None}
    transcript = _tool("session_transcript")
    assert transcript.prepare_arguments({"last_n": "+4", "since_uuid": "12"}) == {
        "last_n": 4, "since_uuid": "12"}
