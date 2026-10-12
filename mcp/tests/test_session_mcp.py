"""session_mcp_set: an orchestrator hands a session's Claude one MCP server and its token.

The install script is the real one, run by the real bash and jq against a
directory standing in for the session's Claude config; only `docker exec` is
replaced. The seed and its first-start install are the shipped shell functions.
"""
import json
import os
import subprocess
from pathlib import Path

import pytest
from mcp.server.fastmcp import FastMCP

from aidc_mcp import scope, session_mcp, tools

REPO = Path(__file__).resolve().parents[2]
TOKEN = "tok-A1b2_C3d4.e5f6~g7h8+i9j0/k1l2=m3n4"
OTHER = "tok-ZZZZ_second.token~0000"
BASE = "http://orchestrator.local:8002"
PATH = "/api/v1/internal/project/mcp"


class Box:
    """A session's container, as far as the install script can tell: its Claude config
    directory, and the seed `aidc create` left for its first start."""

    def __init__(self, tmp_path: Path):
        self.home = tmp_path / "home"
        self.config = self.home / ".claude"
        self.seed = tmp_path / "audit" / "claude-state-seed.json"
        self.config.mkdir(parents=True)
        self.seed.parent.mkdir(parents=True)
        self.state = self.config / ".claude.json"
        self.store = self.config / "aidc-mcp"
        self.runs: list[dict] = []

    def run(self, container: str, payload: str, timeout: float):
        """What session_mcp._exec does, minus docker: the same script, the same stdin."""
        argv = ["bash", "-c", session_mcp.INSTALL_SCRIPT]
        self.runs.append({"container": container, "argv": argv, "input": payload})
        env = {"PATH": os.environ["PATH"], "HOME": str(self.home),
               "CLAUDE_CONFIG_DIR": str(self.config), "AIDC_CLAUDE_STATE_SEED": str(self.seed)}
        return subprocess.run(argv, input=payload, capture_output=True, text=True,
                              timeout=timeout, env=env)

    def hand(self, token: str = TOKEN, *, server: str = "project", path: str = PATH):
        return session_mcp.hand("sandbox", server=server, path=path, bearer=token,
                                base_url=BASE, run=self.run)

    def installed(self, state: dict | None = None) -> None:
        """The session's first start has run: its Claude state is in place."""
        self.state.write_text(json.dumps(state if state is not None
                                         else {"hasCompletedOnboarding": True, "theme": "dark"}))

    def headers(self, server: str = "project") -> dict:
        """What Claude Code gets from the helper when it connects to `server`."""
        out = subprocess.run([str(self.store / "headers.sh")], capture_output=True, text=True,
                             env={"PATH": os.environ["PATH"],
                                  "CLAUDE_CODE_MCP_SERVER_NAME": server}, check=True)
        return json.loads(out.stdout)

    def files_holding(self, text: str) -> list[str]:
        return sorted(str(p.relative_to(self.home.parent)) for p in self.home.parent.rglob("*")
                      if p.is_file() and text in p.read_text(errors="replace"))


@pytest.fixture
def box(tmp_path):
    return Box(tmp_path)


def _shell(script: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", script, "bash", *args], capture_output=True, text=True)


class TestWhatIsWritten:
    def test_the_server_is_in_claudes_state_and_the_token_is_beside_it(self, box):
        box.installed()

        handed = box.hand()

        assert handed == session_mcp.Handed(server="project", url=BASE + PATH, entry="added")
        state = json.loads(box.state.read_text())
        assert state == {
            "hasCompletedOnboarding": True, "theme": "dark",
            "mcpServers": {"project": {"type": "http", "url": BASE + PATH,
                                       "headersHelper": str(box.store / "headers.sh")}},
        }
        assert (box.store / "project.bearer").read_text() == TOKEN
        assert box.headers() == {"Authorization": f"Bearer {TOKEN}"}

    def test_the_token_is_in_one_file_only_and_private(self, box):
        box.installed()
        box.hand()

        assert box.files_holding(TOKEN) == ["home/.claude/aidc-mcp/project.bearer"]
        assert oct((box.store / "project.bearer").stat().st_mode & 0o777) == "0o600"
        assert oct(box.store.stat().st_mode & 0o777) == "0o700"
        assert oct(box.state.stat().st_mode & 0o777) == "0o600"

    def test_a_new_token_replaces_the_old_and_leaves_claudes_state_alone(self, box):
        """Claude Code rewrites .claude.json as it runs, so a session that already has
        the server gets its new token without that file being touched."""
        box.installed()
        box.hand()
        before = (box.state.stat().st_ino, box.state.stat().st_mtime_ns, box.state.read_bytes())

        again = box.hand(OTHER)

        assert again.entry == "unchanged"
        assert (box.state.stat().st_ino, box.state.stat().st_mtime_ns, box.state.read_bytes()) == before
        assert box.headers() == {"Authorization": f"Bearer {OTHER}"}
        assert box.files_holding(TOKEN) == [], "the old token was left somewhere"

    def test_a_server_moved_to_another_path_is_written_again(self, box):
        box.installed()
        box.hand()

        moved = box.hand(path="/api/v2/mcp")

        assert moved.entry == "added"
        assert json.loads(box.state.read_text())["mcpServers"]["project"]["url"] == BASE + "/api/v2/mcp"

    def test_two_servers_keep_their_own_tokens(self, box):
        box.installed()
        box.hand()
        box.hand(OTHER, server="other", path="/other/mcp")

        assert sorted(json.loads(box.state.read_text())["mcpServers"]) == ["other", "project"]
        assert box.headers("project") == {"Authorization": f"Bearer {TOKEN}"}
        assert box.headers("other") == {"Authorization": f"Bearer {OTHER}"}
        assert box.headers("nobody") == {}

    def test_a_session_with_no_seed_and_no_state_gets_a_state_holding_the_server(self, box):
        handed = box.hand()

        assert handed.entry == "added"
        assert list(json.loads(box.state.read_text())) == ["mcpServers"]


class TestItIsWrittenAfterTheSeed:
    """A new session's Claude state comes from a seed with every mcpServers entry
    stripped, installed on the first start only if no state is there yet."""

    def test_while_the_seed_waits_nothing_is_written_and_the_seed_still_lands(self, box):
        box.seed.write_text(json.dumps({"hasCompletedOnboarding": True}))

        with pytest.raises(session_mcp.SessionMcpError) as refused:
            box.hand()

        assert refused.value.code == "session_not_ready"
        assert not box.state.exists(), "a state written first would stop the seed being installed"
        assert not box.store.exists() and box.files_holding(TOKEN) == []
        # The first start, as user-main.sh runs it.
        installed = _shell('. "$1"; aidc_install_claude_state_seed "$2" "$3"',
                           str(REPO / ".devcontainer/claude-state-install.sh"),
                           str(box.config), str(box.seed))
        assert installed.returncode == 0, "the seed was not installed"
        assert box.hand().entry == "added"
        assert json.loads(box.state.read_text())["hasCompletedOnboarding"] is True

    def test_the_hosts_servers_are_stripped_and_the_handed_one_is_the_only_one(self, box, tmp_path):
        """The whole order: the host's state, the strip, the first start, then the hand."""
        host = tmp_path / "host-claude.json"
        host.write_text(json.dumps({
            "hasCompletedOnboarding": True,
            "mcpServers": {"corp": {"command": "x", "env": {"CORP_TOKEN": "hunter2"}},
                           "project": {"type": "http", "url": "http://elsewhere/mcp",
                                       "headers": {"Authorization": "Bearer host-own"}}},
        }))
        seeded = _shell('. "$1"; aidc_claude_state_seed "$2" /code/app /code > "$3"',
                        str(REPO / "scripts/lib/claude-state.sh"), str(host), str(box.seed))
        assert seeded.returncode == 0, seeded.stderr
        assert "mcpServers" not in json.loads(box.seed.read_text())
        host.unlink()   # the host's own file never enters the session
        _shell('. "$1"; aidc_install_claude_state_seed "$2" "$3"',
               str(REPO / ".devcontainer/claude-state-install.sh"), str(box.config), str(box.seed))

        box.hand()

        assert json.loads(box.state.read_text())["mcpServers"] == {
            "project": {"type": "http", "url": BASE + PATH,
                        "headersHelper": str(box.store / "headers.sh")}}
        assert box.files_holding("hunter2") == [] and box.files_holding("host-own") == []


class TestTheTokenStaysOutOfSight:
    def test_it_goes_in_on_standard_input_and_never_in_a_command_line(self, monkeypatch):
        seen = {}

        def fake_run(argv, **kwargs):
            seen["argv"], seen["kwargs"] = argv, kwargs
            return subprocess.CompletedProcess(argv, 0, stdout="added\n", stderr="")

        monkeypatch.setattr(session_mcp.subprocess, "run", fake_run)

        session_mcp.hand("sandbox", server="project", path=PATH, bearer=TOKEN, base_url=BASE)

        assert seen["argv"][:6] == ["docker", "exec", "-i", "-u", "vscode", "aidc-sandbox-dev"]
        assert not any(TOKEN in part for part in seen["argv"]), "the token is in the command line"
        assert json.loads(seen["kwargs"]["input"]) == {"server": "project", "url": BASE + PATH,
                                                       "bearer": TOKEN}

    def test_an_error_that_quotes_it_is_given_back_without_it(self):
        def run(container, payload, timeout):
            return subprocess.CompletedProcess([], 1, stdout="",
                                               stderr=f"jq: error near {TOKEN} at line 1")

        with pytest.raises(session_mcp.SessionMcpError) as failed:
            session_mcp.hand("sandbox", server="project", path=PATH, bearer=TOKEN,
                             base_url=BASE, run=run)

        assert TOKEN not in str(failed.value)
        assert "jq: error near [bearer] at line 1" in str(failed.value)
        assert failed.value.code == "command_failed"

    def test_a_session_that_is_gone_is_said_to_be_gone(self):
        def run(container, payload, timeout):
            return subprocess.CompletedProcess(
                [], 1, stdout="", stderr="Error response from daemon: No such container: aidc-gone-dev")

        with pytest.raises(session_mcp.SessionMcpError) as failed:
            session_mcp.hand("gone", server="project", path=PATH, bearer=TOKEN, base_url=BASE, run=run)

        assert (str(failed.value), failed.value.code) == ("no such session: gone", "no_such_session")


class TestWhatIsRefused:
    @pytest.mark.parametrize("server", ["", "Project", "a b", "../x", "x" * 32, "-x", "a/b"])
    def test_a_server_name_that_is_not_a_plain_name(self, box, server):
        box.installed()
        with pytest.raises(session_mcp.SessionMcpError) as refused:
            box.hand(server=server)
        assert refused.value.code == "invalid_argument" and box.runs == []

    @pytest.mark.parametrize("path", ["", "api/mcp", "http://evil.example/mcp", "//evil.example/mcp",
                                      "/a/../b", "/mcp?x=1", "/mcp#f", "/mcp x", "/@evil.example"])
    def test_a_path_that_could_name_another_host_or_is_not_a_path(self, box, path):
        """The host is this server's to say: the caller gives only a path on it."""
        box.installed()
        with pytest.raises(session_mcp.SessionMcpError) as refused:
            box.hand(path=path)
        assert refused.value.code == "invalid_argument" and box.runs == []

    @pytest.mark.parametrize("token", ["", "two words", "line\nbreak", "quote\"d", "semi;colon",
                                       "$(id)", "x" * 4097])
    def test_a_token_a_header_or_a_shell_could_misread(self, box, token):
        box.installed()
        with pytest.raises(session_mcp.SessionMcpError) as refused:
            box.hand(token)
        assert refused.value.code == "invalid_argument" and box.runs == []
        assert not token or token not in str(refused.value)

    def test_a_server_with_no_callback_address_configured(self, box):
        box.installed()
        with pytest.raises(session_mcp.SessionMcpError) as refused:
            session_mcp.hand("sandbox", server="project", path=PATH, bearer=TOKEN,
                             base_url="", run=box.run)
        assert refused.value.code == "not_configured" and box.runs == []


# --- the tool ------------------------------------------------------------------

def _tool(name):
    app = FastMCP("t")
    tools.register(app)
    return app._tool_manager._tools[name].fn


def _audit_log(tmp_path) -> str:
    log = tmp_path / "access.log"
    return log.read_text() if log.exists() else ""


@pytest.fixture
def wired(box, monkeypatch):
    """The tool over the box: the real script, a configured callback address, Claude running."""
    box.installed()
    box.claude_running = True
    monkeypatch.setattr(tools, "_metallm_callback_url", lambda: BASE)
    real_hand = session_mcp.hand

    def hand(name, **kwargs):
        return real_hand(name, run=box.run, **kwargs)

    async def running(_container):
        return box.claude_running

    monkeypatch.setattr(session_mcp, "hand", hand)
    monkeypatch.setattr(tools, "_is_claude_running", running)
    return box


class TestTheTool:
    async def test_it_returns_where_the_server_is_and_never_the_token(self, wired, tmp_path):
        res = await _tool("session_mcp_set")(name="sandbox", server="project", path=PATH, bearer=TOKEN)

        assert res == {"ok": True, "data": {
            "session": "sandbox", "server": "project", "url": BASE + PATH, "entry": "added",
            "needs_claude_restart": True,
            "applies": tools._MCP_NEEDS_RESTART.format(name="sandbox"),
        }}
        assert TOKEN not in json.dumps(res)
        logged = _audit_log(tmp_path)
        assert '"tool":"session_mcp_set"' in logged and TOKEN not in logged

    async def test_a_new_token_for_a_server_claude_already_has_needs_no_restart(self, wired):
        await _tool("session_mcp_set")(name="sandbox", server="project", path=PATH, bearer=TOKEN)

        res = await _tool("session_mcp_set")(name="sandbox", server="project", path=PATH, bearer=OTHER)

        assert (res["data"]["entry"], res["data"]["needs_claude_restart"]) == ("unchanged", False)
        assert res["data"]["applies"] == tools._MCP_LIVE
        assert OTHER not in json.dumps(res)

    async def test_a_new_server_with_claude_not_running_needs_no_restart(self, wired):
        wired.claude_running = False

        res = await _tool("session_mcp_set")(name="sandbox", server="project", path=PATH, bearer=TOKEN)

        assert (res["data"]["entry"], res["data"]["needs_claude_restart"]) == ("added", False)
        assert res["data"]["applies"] == tools._MCP_ON_START

    async def test_a_refusal_logs_nothing_the_caller_gave(self, wired, tmp_path):
        """An argument in the wrong place could be the token."""
        res = await _tool("session_mcp_set")(name="sandbox", server=TOKEN, path=PATH, bearer="x y")

        assert (res["ok"], res["error_code"]) == (False, "invalid_argument")
        assert TOKEN not in json.dumps(res) and TOKEN not in _audit_log(tmp_path)

    async def test_a_failure_in_the_session_is_an_error_without_the_token(self, wired, tmp_path, monkeypatch):
        def broken(name, **kwargs):
            raise session_mcp.SessionMcpError(
                session_mcp.scrub(f"the session's Claude state was not written: near {TOKEN}", TOKEN),
                "command_failed")

        monkeypatch.setattr(session_mcp, "hand", broken)

        res = await _tool("session_mcp_set")(name="sandbox", server="project", path=PATH, bearer=TOKEN)

        assert (res["ok"], res["error_code"]) == (False, "command_failed")
        assert TOKEN not in json.dumps(res) and TOKEN not in _audit_log(tmp_path)

    async def test_no_other_tools_result_or_file_holds_the_token(self, wired, tmp_path, monkeypatch):
        """Status and the listing read the CLI; neither reads the session's Claude config."""
        await _tool("session_mcp_set")(name="sandbox", server="project", path=PATH, bearer=TOKEN)
        monkeypatch.setattr(tools, "_run_cli", lambda args, timeout=60.0: {
            "exit": 0, "stdout": "NAME STATUS\nsandbox running\n", "stderr": ""})

        status = await _tool("session_status")(name="sandbox")
        listing = await _tool("session_list")()

        assert TOKEN not in json.dumps([status, listing])
        assert wired.files_holding(TOKEN) == ["home/.claude/aidc-mcp/project.bearer"]

    async def test_a_scoped_server_refuses_another_session(self, wired, monkeypatch):
        monkeypatch.setenv(scope.ENV, "other")

        res = await _tool("session_mcp_set")(name="sandbox", server="project", path=PATH, bearer=TOKEN)

        assert res["error_code"] == "out_of_scope" and wired.runs == []


class TestAtCreate:
    @pytest.fixture
    def created(self, wired, monkeypatch):
        """session_create over a CLI that succeeds; what ran, in order."""
        monkeypatch.setenv(scope.ENABLE_CREATE_ENV, "true")
        monkeypatch.delenv("AIDC_HOST_HOME", raising=False)
        order: list[str] = []
        wired.cli = {"exit": 0, "stdout": "Healthy\n", "stderr": ""}

        def cli(args, timeout=60.0):
            order.append(f"cli:{args[0]}")
            return wired.cli

        real_run = wired.run

        def run(container, payload, timeout):
            order.append("hand")
            return real_run(container, payload, timeout)

        wired.run = run
        monkeypatch.setattr(tools, "_run_cli", cli)
        wired.order = order
        return wired

    async def test_the_server_is_handed_after_the_session_is_created(self, created):
        res = await _tool("session_create")(
            name="sandbox", repo="/code/app", mcp_server="project", mcp_path=PATH, mcp_bearer=TOKEN)

        assert created.order == ["cli:create", "hand"]
        assert res["ok"] is True and res["data"]["mcp"]["data"]["entry"] == "added"
        assert TOKEN not in json.dumps(res)

    async def test_a_create_that_failed_hands_nothing(self, created):
        created.cli = {"exit": 1, "stdout": "", "stderr": "boom"}

        res = await _tool("session_create")(
            name="sandbox", repo="/code/app", mcp_server="project", mcp_path=PATH, mcp_bearer=TOKEN)

        assert res["ok"] is False and created.order == ["cli:create"]

    async def test_a_server_that_cannot_be_handed_creates_nothing(self, created):
        res = await _tool("session_create")(
            name="sandbox", repo="/code/app", mcp_server="project", mcp_path="http://evil/mcp",
            mcp_bearer=TOKEN)

        assert (res["ok"], res["error_code"]) == (False, "invalid_argument")
        assert created.order == []

    async def test_without_the_option_nothing_is_handed(self, created):
        res = await _tool("session_create")(name="sandbox", repo="/code/app")

        assert res == {"ok": True, "data": {"name": "sandbox", "log": "Healthy\n"}}
        assert created.order == ["cli:create"]
