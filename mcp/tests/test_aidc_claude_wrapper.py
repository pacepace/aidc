"""Tests for the `aidc-claude` wrapper baked into .devcontainer/Dockerfile.

The wrapper is the PRIMARY fix for the AskUserQuestion deadlock (Layer 1): it
denies the interactive-input tools so an orchestrated, no-human session never
renders a widget the paste+Enter path can't answer. Layer 2 (transcript.py) is
only the safety net. This extracts the wrapper's shell body from the Dockerfile
heredoc and runs it against a stub `claude` that records the argv it receives, so
a future edit that drops the deny, loses the prompt, or reorders the args past
the trailing variadic is caught by a failing test.
"""
import os
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DOCKERFILE = REPO / ".devcontainer" / "Dockerfile"


def _extract_wrapper() -> str:
    src = DOCKERFILE.read_text(encoding="utf-8")
    m = re.search(
        r"RUN cat > /usr/local/bin/aidc-claude <<'EOF'.*?\n(#!/usr/bin/env bash.*?)\nEOF",
        src, re.S,
    )
    assert m, "aidc-claude wrapper heredoc not found in .devcontainer/Dockerfile"
    return m.group(1)


def _run_wrapper(tmp_path: Path, argv, env_extra=None):
    """Run the extracted wrapper with a stub claude; return the argv the stub saw."""
    wrapper = tmp_path / "aidc-claude"
    wrapper.write_text(_extract_wrapper(), encoding="utf-8")
    wrapper.chmod(0o755)

    home = tmp_path / "home"
    binp = home / ".local" / "bin"
    binp.mkdir(parents=True)
    seen = tmp_path / "seen.txt"
    stub = binp / "claude"
    stub.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$AIDC_TEST_SEEN"\n',
                    encoding="utf-8")
    stub.chmod(0o755)

    env = dict(os.environ)
    env["HOME"] = str(home)                 # wrapper execs ${HOME}/.local/bin/claude
    env["AIDC_TEST_SEEN"] = str(seen)
    if env_extra:
        env.update(env_extra)
    subprocess.run(["bash", str(wrapper), *argv], env=env, check=True)
    return seen.read_text(encoding="utf-8").splitlines()


def _wrapper_returncode(tmp_path, argv, env_extra=None):
    """Run the wrapper expecting it may exit non-zero (e.g. unknown mode); return
    the exit code without requiring the stub to have run."""
    wrapper = tmp_path / "aidc-claude"
    wrapper.write_text(_extract_wrapper(), encoding="utf-8")
    wrapper.chmod(0o755)
    env = dict(os.environ)
    env["HOME"] = str(tmp_path / "home")
    env["AIDC_TEST_SEEN"] = str(tmp_path / "seen.txt")
    if env_extra:
        env.update(env_extra)
    return subprocess.run(["bash", str(wrapper), *argv], env=env,
                          capture_output=True).returncode


class TestAidcClaudeWrapper:
    def test_yolo_default_denies_all_human_in_the_loop_tools(self, tmp_path):
        argv = _run_wrapper(tmp_path, ["--print", "hello world"])
        # default mode is yolo: all three denied + the strong skip-permissions flag
        assert argv.count("--disallowedTools") == 3
        assert "AskUserQuestion" in argv   # multiple-choice widget
        assert "ExitPlanMode" in argv      # plan-approval widget
        assert "EnterPlanMode" in argv     # enters plan mode (no human to approve exit)
        assert "--dangerously-skip-permissions" in argv

    def test_prompt_preserved_before_our_flags(self, tmp_path):
        argv = _run_wrapper(tmp_path, ["--print", "hello world"])
        assert "hello world" in argv          # prompt survived as one arg
        assert "--print" in argv
        # user args are exec'd BEFORE our injected flags, so the --disallowedTools
        # variadic can never swallow the prompt. A revert to args-first breaks this.
        assert argv.index("hello world") < argv.index("--disallowedTools")

    def test_plan_mode_allows_the_plan_tools(self, tmp_path):
        # plan mode is BUILT ON the plan tools, so they must NOT be denied — only
        # AskUserQuestion (still undrivable) stays denied.
        argv = _run_wrapper(tmp_path, ["--print", "x"], {"AIDC_CLAUDE_MODE": "plan"})
        assert argv.count("--disallowedTools") == 1
        assert "AskUserQuestion" in argv
        assert "ExitPlanMode" not in argv
        assert "EnterPlanMode" not in argv
        assert "--permission-mode" in argv and "plan" in argv

    def test_safe_aliases_default_mode_and_still_denies(self, tmp_path):
        argv = _run_wrapper(tmp_path, ["--print", "x"], {"AIDC_CLAUDE_MODE": "safe"})
        assert "--dangerously-skip-permissions" not in argv
        assert "--permission-mode" in argv and "default" in argv
        assert argv.count("--disallowedTools") == 3   # non-plan -> full deny
        assert "x" in argv

    def test_native_mode_passes_through_to_permission_mode(self, tmp_path):
        argv = _run_wrapper(tmp_path, ["--print", "x"], {"AIDC_CLAUDE_MODE": "acceptEdits"})
        assert "--permission-mode" in argv
        assert argv[argv.index("--permission-mode") + 1] == "acceptEdits"
        assert "--dangerously-skip-permissions" not in argv
        assert argv.count("--disallowedTools") == 3   # non-plan -> full deny

    def test_unknown_mode_exits_nonzero(self, tmp_path):
        assert _wrapper_returncode(tmp_path, ["--print", "x"],
                                   {"AIDC_CLAUDE_MODE": "bogus"}) == 2
