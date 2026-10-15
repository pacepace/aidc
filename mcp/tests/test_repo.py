"""The read-only repository tools, run against a REAL git repository on this machine.

In production every command runs inside the session's dev container
(`repo.in_session`); here that one seam is replaced so the same argument list runs
locally, against a temporary repository. Everything else is the real code: the
argument lists, the byte cap, the parsing and file_get's shell script.
"""
import os
import subprocess

import pytest
from mcp.server.fastmcp import FastMCP

from aidc_mcp import repo, tools
from aidc_mcp import session_facts as sf


def _git(cwd, *args):
    subprocess.run(["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args],
                   cwd=cwd, check=True, capture_output=True)


@pytest.fixture
def repo_dir(tmp_path, monkeypatch):
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q", "-b", "main")
    (root / "a.txt").write_text("one\ntwo\n-foo here\n")
    (root / "src").mkdir()
    (root / "src" / "mod.py").write_text("def f():\n    return 1\n")
    _git(root, "add", ".")
    _git(root, "commit", "-qm", "first")
    _git(root, "branch", "feature/x")
    (root / "a.txt").write_text("one\ntwo changed\n-foo here\n")
    (root / "new.md").write_text("new file\n")
    (tmp_path / "outside.txt").write_text("secret outside\n")
    real = os.path.realpath(root)

    def local(name, repo_path, inner):
        assert repo_path == real
        return inner, repo_path
    monkeypatch.setattr(repo, "in_session", local)

    async def repo_path(name):
        return real
    monkeypatch.setattr(sf, "repo_path", repo_path)
    return real


def _tool(name):
    app = FastMCP("t")
    tools.register(app)
    return app._tool_manager._tools[name].fn


# --- the argument list itself ----------------------------------------------------

def test_every_command_runs_in_the_dev_container_as_its_user():
    argv, cwd = repo.in_session("proj", "/r", ["git", "status"])
    assert argv[:7] == ["docker", "exec", "-u", "vscode", "-w", "/r", "-e"]
    assert "aidc-proj-dev" in argv and cwd is None
    assert argv[argv.index("aidc-proj-dev") + 1:][:4] == ["timeout", "-k", "5", str(repo.GIT_TIMEOUT_S)]
    assert "GIT_OPTIONAL_LOCKS=0" in argv


def test_git_never_runs_the_repositorys_fsmonitor_pager_or_diff_drivers():
    assert repo._GIT[:6] == ["git", "-c", "core.fsmonitor=false", "-c", "core.pager=cat",
                             "--no-pager"]
    assert "--literal-pathspecs" in repo._GIT
    assert {"--no-ext-diff", "--no-textconv"} <= set(repo._DIFF_SAFE)


# --- good traffic ------------------------------------------------------------------

async def test_status(repo_dir):
    res = await _tool("repo_status")(name="proj")
    assert res["ok"] is True
    d = res["data"]
    assert d["branch"] == "main" and d["head"] and d["untrusted"] is True
    assert {"path": "a.txt", "status": ".M"} in d["changes"]
    assert {"path": "new.md", "status": "untracked"} in d["changes"]


async def test_diff(repo_dir):
    res = await _tool("repo_diff")(name="proj")
    assert res["ok"] is True
    assert "+two changed" in res["data"]["diff"] and res["data"]["cut"] is False


async def test_diff_against_a_ref_and_a_path(repo_dir):
    res = await _tool("repo_diff")(name="proj", ref="HEAD", path="a.txt")
    assert "+two changed" in res["data"]["diff"] and res["data"]["path"] == "a.txt"
    res = await _tool("repo_diff")(name="proj", ref="HEAD", path=f"{repo_dir}/src")
    assert res["ok"] is True and res["data"]["diff"] == "" and res["data"]["path"] == "src"


async def test_log(repo_dir):
    res = await _tool("repo_log")(name="proj", ref="feature/x")
    assert [c["subject"] for c in res["data"]["commits"]] == ["first"]
    assert res["data"]["commits"][0]["author"] == "t"


async def test_branches(repo_dir):
    res = await _tool("repo_branches")(name="proj")
    assert res["data"]["current"] == "main"
    assert {b["name"] for b in res["data"]["branches"]} == {"main", "feature/x"}


async def test_file_list(repo_dir):
    res = await _tool("file_list")(name="proj")
    assert set(res["data"]["files"]) == {"a.txt", "src/mod.py", "new.md"}
    res = await _tool("file_list")(name="proj", pattern="*.py")
    assert res["data"]["files"] == ["src/mod.py"] and res["data"]["total"] == 1


async def test_file_search_finds_a_pattern_starting_with_a_dash(repo_dir):
    res = await _tool("file_search")(name="proj", pattern="-foo")
    assert res["ok"] is True
    assert res["data"]["matches"] == [{"path": "a.txt", "line": 3, "text": "-foo here"}]


async def test_file_search_no_match_is_empty(repo_dir):
    res = await _tool("file_search")(name="proj", pattern="nothing like this")
    assert res["ok"] is True and res["data"]["matches"] == []


# --- a ref is never an option ----------------------------------------------------

@pytest.mark.parametrize("tool", ["repo_diff", "repo_log"])
async def test_a_ref_starting_with_a_dash_writes_no_file(tool, repo_dir, tmp_path):
    target = tmp_path / "pwned"
    res = await _tool(tool)(name="proj", ref=f"--output={target}")
    assert not target.exists()
    assert res["ok"] is False and res["error_code"] == "command_failed"
    assert "bad revision" in res["error"] or "unknown revision" in res["error"] \
        or "ambiguous argument" in res["error"]


# --- paths stay inside the repository -----------------------------------------------

@pytest.mark.parametrize("tool,args", [
    ("repo_diff", {"path": "../outside.txt"}),
    ("repo_diff", {"path": "/etc"}),
    ("repo_log", {"path": "src/../../outside.txt"}),
    ("file_list", {"path": "/etc"}),
    ("file_search", {"pattern": "secret", "path": "../"}),
])
async def test_a_path_outside_the_repository_is_refused(tool, args, repo_dir):
    res = await _tool(tool)(name="proj", **args)
    assert res["ok"] is False and res["error_code"] == "outside_repo"


def test_inside_keeps_paths_in_the_repository():
    assert repo.inside("/r", "src/a.py") == "src/a.py"
    assert repo.inside("/r", "/r/src") == "src"
    assert repo.inside("/r", "") == "" and repo.inside("/r", "/r") == ""
    for bad in ("../x", "/rx/y", "/etc/passwd", "a/../../x"):
        with pytest.raises(repo.RepoRefusal):
            repo.inside("/r", bad)


# --- the byte cap ------------------------------------------------------------------

async def test_a_50_mb_diff_comes_back_capped_and_the_process_is_stopped(repo_dir):
    big = os.path.join(repo_dir, "big.txt")
    with open(big, "w") as fh:
        fh.write("")
    _git(repo_dir, "add", "big.txt")
    _git(repo_dir, "commit", "-qm", "empty")
    with open(big, "w") as fh:
        line = "x" * 99 + "\n"
        fh.write(line * (50 * 1024 * 1024 // len(line)))
    res = await _tool("repo_diff")(name="proj", path="big.txt")
    assert res["ok"] is True
    assert res["data"]["cut"] is True
    assert res["data"]["bytes"] == repo.DIFF_CAP
    # and the reader stopped git rather than reading the rest
    ran = await repo.run_capped(["git", "--no-pager", "diff", "--", "big.txt"],
                                cwd=repo_dir, cap=1000)
    assert ran.cut is True and len(ran.stdout) == 1000 and ran.returncode < 0


# --- file_get: confined by the resolved path --------------------------------------

async def test_file_get_reads_a_file(repo_dir):
    res = await _tool("file_get")(name="proj", path="src/mod.py")
    assert res["ok"] is True
    d = res["data"]
    assert d["content"] == "def f():\n    return 1\n" and d["encoding"] == "utf-8"
    assert d["path"] == f"{repo_dir}/src/mod.py" and d["more"] is False


@pytest.mark.parametrize("path", ["/etc/passwd", "../outside.txt", "src/../../outside.txt",
                                  "/etc/no-such-file-anywhere"])
async def test_file_get_refuses_a_path_outside(path, repo_dir):
    res = await _tool("file_get")(name="proj", path=path)
    assert res["ok"] is False and res["error_code"] == "outside_repo"
    assert "secret" not in str(res)


async def test_file_get_refuses_a_symlink_that_points_out(repo_dir, tmp_path):
    os.symlink(tmp_path / "outside.txt", os.path.join(repo_dir, "link.txt"))
    res = await _tool("file_get")(name="proj", path="link.txt")
    assert res["ok"] is False and res["error_code"] == "outside_repo"
    assert "secret outside" not in str(res)


async def test_file_get_follows_a_symlink_that_stays_inside(repo_dir):
    os.symlink(os.path.join(repo_dir, "src", "mod.py"), os.path.join(repo_dir, "alias.py"))
    res = await _tool("file_get")(name="proj", path="alias.py")
    assert res["ok"] is True and res["data"]["content"].startswith("def f()")


async def test_file_get_missing_and_directory(repo_dir):
    res = await _tool("file_get")(name="proj", path="nope.txt")
    assert res["error_code"] == "not_found"
    res = await _tool("file_get")(name="proj", path="src")
    assert res["error_code"] == "invalid_argument"


async def test_file_get_windows(repo_dir):
    with open(os.path.join(repo_dir, "w.txt"), "w") as fh:
        fh.write("0123456789")
    res = await _tool("file_get")(name="proj", path="w.txt", offset=3, limit=4)
    d = res["data"]
    assert d["content"] == "3456" and d["size"] == 10 and d["returned"] == 4
    assert d["more"] is True and d["next_offset"] == 7


async def test_file_get_past_the_cap_says_there_is_more(repo_dir):
    with open(os.path.join(repo_dir, "big.txt"), "w") as fh:
        fh.write("y" * (repo.FILE_MAX_LIMIT + 5))
    res = await _tool("file_get")(name="proj", path="big.txt", limit=repo.FILE_MAX_LIMIT)
    d = res["data"]
    assert d["returned"] == repo.FILE_MAX_LIMIT and d["more"] is True
    assert d["next_offset"] == repo.FILE_MAX_LIMIT
    res = await _tool("file_get")(name="proj", path="big.txt", limit=repo.FILE_MAX_LIMIT + 1)
    assert res["error_code"] == "invalid_argument"


async def test_file_get_leaves_a_cut_character_for_the_next_window(repo_dir):
    with open(os.path.join(repo_dir, "u.txt"), "w", encoding="utf-8") as fh:
        fh.write("abécd")  # é is two bytes, at offsets 2-3
    res = await _tool("file_get")(name="proj", path="u.txt", limit=3)
    assert res["data"]["content"] == "ab" and res["data"]["next_offset"] == 2


async def test_file_get_binary_is_base64(repo_dir):
    with open(os.path.join(repo_dir, "b.bin"), "wb") as fh:
        fh.write(b"\xff\xfe\x00\x01\xff\xff")
    res = await _tool("file_get")(name="proj", path="b.bin")
    assert res["data"]["encoding"] == "base64"
