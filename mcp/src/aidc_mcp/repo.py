"""Read-only looks at a session's repository: status, diff, log, branches, files.

The repository is the session's, and so is everything in it that git would run:
`core.fsmonitor`, a pager, an external diff driver, a textconv filter. Run on the
host or in this server's container, `git status` on that repo runs the session's
code with this server's reach. So every command here runs INSIDE the session's dev
container, as its own user, with fixed argument lists:

- `-c core.fsmonitor=false -c core.pager=cat --no-pager`, and `--no-ext-diff
  --no-textconv` wherever a diff can be produced;
- `--end-of-options` before every ref: a ref of `--output=/somewhere` would
  otherwise be read as an option and write a file;
- a pattern only as the value of `-e`, and every path after `--`, with
  `--literal-pathspecs` so no path is read as pathspec magic;
- `timeout` inside the container (killing `docker exec` on this side does not stop
  the process inside it) and a client-side timeout as well;
- a byte cap on what is read back: past it the process is stopped and the result
  says it was cut.

Paths are relative to the repository or absolute inside it; one that leaves it is
refused before anything runs. What comes back is the repository's text, not
instructions.
"""

from __future__ import annotations

import asyncio
import base64
import fnmatch
import posixpath
from dataclasses import dataclass
from typing import Any

# Bytes read back before the process is stopped.
DIFF_CAP = 200_000
READ_CAP = 64_000
# Seconds a git command may run inside the container.
GIT_TIMEOUT_S = 30
# file_get's window: the default, and the most one call returns.
FILE_DEFAULT_LIMIT = 100_000
FILE_MAX_LIMIT = 200_000

_GIT = ["git", "-c", "core.fsmonitor=false", "-c", "core.pager=cat", "--no-pager",
        "--literal-pathspecs"]
_DIFF_SAFE = ["--no-ext-diff", "--no-textconv", "--no-color"]

_STDERR_CAP = 8_000


class RepoRefusal(Exception):
    """A call that cannot run as asked; `code` is one of the server's error codes."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class Ran:
    returncode: int
    stdout: bytes
    stderr: str
    #: stdout went past the cap and the process was stopped
    cut: bool


def in_session(name: str, repo: str, inner: list[str]) -> tuple[list[str], str | None]:
    """The argv that runs `inner` in the session's dev container, in its repository, as
    its user, under `timeout`; and the local working dir (None: the container's).
    The seam tests replace to run `inner` against a repository on this machine."""
    return ([
        "docker", "exec", "-u", "vscode", "-w", repo,
        "-e", "GIT_OPTIONAL_LOCKS=0", "-e", "GIT_TERMINAL_PROMPT=0", "-e", "GIT_PAGER=cat",
        f"aidc-{name}-dev", "timeout", "-k", "5", str(GIT_TIMEOUT_S), *inner,
    ], None)


async def run_capped(argv: list[str], *, cwd: str | None, cap: int,
                     timeout: float = GIT_TIMEOUT_S + 10) -> Ran:
    """Run argv, keeping at most `cap` bytes of stdout. Past the cap the process is
    killed and `cut` is set; past `timeout` it is killed and RepoRefusal(timeout)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv, cwd=cwd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except OSError as exc:
        return Ran(-1, b"", str(exc), False)
    assert proc.stdout is not None and proc.stderr is not None
    stdout, stderr = proc.stdout, proc.stderr
    out = bytearray()
    err = bytearray()
    cut = False

    async def read_out() -> None:
        nonlocal cut
        while True:
            chunk = await stdout.read(65536)
            if not chunk:
                return
            room = cap - len(out)
            if len(chunk) > room:
                out.extend(chunk[:room])
                cut = True
                proc.kill()
                return
            out.extend(chunk)

    async def read_err() -> None:
        while True:
            chunk = await stderr.read(65536)
            if not chunk:
                return
            if len(err) < _STDERR_CAP:
                err.extend(chunk[: _STDERR_CAP - len(err)])

    try:
        await asyncio.wait_for(asyncio.gather(read_out(), read_err()), timeout=timeout)
        rc = await asyncio.wait_for(proc.wait(), timeout=10)
    except TimeoutError:
        proc.kill()
        await proc.wait()
        raise RepoRefusal(
            "timeout", f"the command ran past {timeout:.0f}s and was stopped") from None
    return Ran(rc, bytes(out), err.decode("utf-8", errors="replace").strip(), cut)


def inside(repo: str, path: str) -> str:
    """`path` as a path relative to `repo` ("" for the repo itself), or RepoRefusal
    (outside_repo) when it leaves it. Lexical: git does not follow a symlink out of
    the work tree, and file_get resolves its own path inside the container."""
    if not path or not path.strip():
        return ""
    root = posixpath.normpath(repo)
    full = posixpath.normpath(path if path.startswith("/") else posixpath.join(root, path))
    if full == root:
        return ""
    if not full.startswith(root.rstrip("/") + "/"):
        raise RepoRefusal("outside_repo",
                          f"'{path}' is outside the session's repository ({root})")
    return full[len(root.rstrip("/")) + 1:]


async def _git(name: str, repo: str, args: list[str], *, cap: int = READ_CAP) -> Ran:
    argv, cwd = in_session(name, repo, [*_GIT, *args])
    return await run_capped(argv, cwd=cwd, cap=cap)


def _failed(ran: Ran, what: str) -> RepoRefusal:
    said = ran.stderr.splitlines()[-1] if ran.stderr else f"exit {ran.returncode}"
    if ran.returncode == 124:
        return RepoRefusal("timeout", f"{what} ran past {GIT_TIMEOUT_S}s and was stopped")
    return RepoRefusal("command_failed", f"{what} failed: {said[:300]}")


def _text(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


# ---- status -------------------------------------------------------------------

async def status(name: str, repo: str) -> dict[str, Any]:
    """Branch, upstream, ahead/behind and every changed path."""
    ran = await _git(name, repo, ["status", "--porcelain=v2", "--branch", "-z"])
    if ran.returncode != 0 and not ran.cut:
        raise _failed(ran, "git status")
    fields = _text(ran.stdout).split("\0")
    out: dict[str, Any] = {"repo": repo, "branch": None, "head": None, "upstream": None,
                           "ahead": 0, "behind": 0, "changes": [], "cut": ran.cut}
    skip = False
    for rec in fields:
        if skip:
            skip = False
            continue
        if not rec:
            continue
        if rec.startswith("# branch.oid "):
            oid = rec.split(" ", 2)[2]
            out["head"] = None if oid == "(initial)" else oid[:12]
        elif rec.startswith("# branch.head "):
            head = rec.split(" ", 2)[2]
            out["branch"] = None if head == "(detached)" else head
        elif rec.startswith("# branch.upstream "):
            out["upstream"] = rec.split(" ", 2)[2]
        elif rec.startswith("# branch.ab "):
            parts = rec.split(" ")
            out["ahead"], out["behind"] = int(parts[2]), -int(parts[3])
        elif rec[0] in "12u":
            # "1 XY sub mH mI mW hH hI path"; "2 ... X<score> path" then the old path;
            # "u XY sub m1 m2 m3 mW h1 h2 h3 path"
            n = {"1": 8, "2": 9, "u": 10}[rec[0]]
            parts = rec.split(" ", n)
            out["changes"].append({"path": parts[-1], "status": parts[1]})
            skip = rec[0] == "2"
        elif rec[0] == "?":
            out["changes"].append({"path": rec[2:], "status": "untracked"})
    return out


# ---- diff ---------------------------------------------------------------------

async def diff(name: str, repo: str, *, ref: str = "", path: str = "",
               staged: bool = False) -> dict[str, Any]:
    """The working tree's diff (or the index's, or against a ref), capped."""
    rel = inside(repo, path)
    args = ["diff", *_DIFF_SAFE]
    if staged:
        args.append("--cached")
    if ref:
        args += ["--end-of-options", ref]
    args += ["--", *([rel] if rel else [])]
    ran = await _git(name, repo, args, cap=DIFF_CAP)
    if ran.returncode != 0 and not ran.cut:
        raise _failed(ran, "git diff")
    return {"repo": repo, "ref": ref, "path": rel, "staged": staged,
            "diff": _text(ran.stdout), "bytes": len(ran.stdout), "cut": ran.cut}


# ---- log ----------------------------------------------------------------------

async def log(name: str, repo: str, *, ref: str = "", path: str = "",
              limit: int = 20) -> dict[str, Any]:
    """The newest commits, newest first: commit, author, date, subject."""
    if not 1 <= limit <= 100:
        raise RepoRefusal("invalid_argument", "limit must be between 1 and 100")
    rel = inside(repo, path)
    args = ["log", *_DIFF_SAFE, "-n", str(limit), "--format=%H%x1f%an%x1f%aI%x1f%s%x1e"]
    if ref:
        args += ["--end-of-options", ref]
    args += ["--", *([rel] if rel else [])]
    ran = await _git(name, repo, args)
    if ran.returncode != 0 and not ran.cut:
        raise _failed(ran, "git log")
    commits = []
    for rec in _text(ran.stdout).split("\x1e"):
        parts = rec.strip("\n").split("\x1f")
        if len(parts) == 4:
            commits.append(dict(zip(("commit", "author", "date", "subject"), parts, strict=True)))
    return {"repo": repo, "ref": ref, "path": rel, "commits": commits, "cut": ran.cut}


# ---- branches -----------------------------------------------------------------

async def branches(name: str, repo: str) -> dict[str, Any]:
    """Local and remote branches with their newest commit; the current branch."""
    fmt = ("--format=%(refname)%1f%(objectname:short)%1f%(committerdate:iso-strict)"
           "%1f%(subject)%1f%(upstream:short)%1e")
    ran = await _git(name, repo, ["for-each-ref", fmt, "refs/heads", "refs/remotes"])
    if ran.returncode != 0 and not ran.cut:
        raise _failed(ran, "git for-each-ref")
    local, remote = [], []
    for rec in _text(ran.stdout).split("\x1e"):
        parts = rec.strip("\n").split("\x1f")
        if len(parts) != 5:
            continue
        ref, commit, date, subject, upstream = parts
        if ref.startswith("refs/heads/"):
            local.append({"name": ref[len("refs/heads/"):], "commit": commit, "date": date,
                          "subject": subject, "upstream": upstream or None})
        elif ref.startswith("refs/remotes/") and not ref.endswith("/HEAD"):
            remote.append({"name": ref[len("refs/remotes/"):], "commit": commit,
                           "date": date, "subject": subject})
    return {"repo": repo, "current": await current_branch(name, repo),
            "branches": local, "remotes": remote, "cut": ran.cut}


async def current_branch(name: str, repo: str) -> str | None:
    """The checked-out branch, or None when detached or unknown."""
    ran = await _git(name, repo, ["symbolic-ref", "-q", "--short", "HEAD"])
    branch = _text(ran.stdout).strip()
    return branch if ran.returncode == 0 and branch else None


async def head(name: str, repo: str) -> str | None:
    """The short id of HEAD, or None."""
    ran = await _git(name, repo, ["rev-parse", "--short=12", "--verify", "-q", "HEAD"])
    sha = _text(ran.stdout).strip()
    return sha if ran.returncode == 0 and sha else None


# ---- files --------------------------------------------------------------------

async def list_files(name: str, repo: str, *, path: str = "", pattern: str = "",
                     limit: int = 500) -> dict[str, Any]:
    """Tracked and untracked (not ignored) files under `path`, matching a glob."""
    if not 1 <= limit <= 5000:
        raise RepoRefusal("invalid_argument", "limit must be between 1 and 5000")
    rel = inside(repo, path)
    ran = await _git(name, repo, ["ls-files", "-z", "--cached", "--others", "--exclude-standard",
                                  "--", *([rel] if rel else [])])
    if ran.returncode != 0 and not ran.cut:
        raise _failed(ran, "git ls-files")
    names = list(dict.fromkeys(p for p in _text(ran.stdout).split("\0") if p))
    if ran.cut and names:
        names.pop()  # the last name may have been cut mid-way
    if pattern:
        names = [n for n in names if fnmatch.fnmatchcase(n, pattern)
                 or ("/" not in pattern and fnmatch.fnmatchcase(posixpath.basename(n), pattern))]
    return {"repo": repo, "path": rel, "pattern": pattern, "files": names[:limit],
            "total": len(names), "cut": ran.cut or len(names) > limit}


async def search(name: str, repo: str, *, pattern: str, path: str = "", regex: bool = False,
                 limit: int = 200) -> dict[str, Any]:
    """Lines matching `pattern` in tracked and untracked files: path, line, text."""
    if not pattern:
        raise RepoRefusal("invalid_argument", "pattern is required")
    if not 1 <= limit <= 2000:
        raise RepoRefusal("invalid_argument", "limit must be between 1 and 2000")
    rel = inside(repo, path)
    # The pattern only as -e's value: `git grep --end-of-options <pattern>` reads the
    # pattern as a revision (measured on git 2.34), and a bare pattern starting with
    # `-` is an option.
    args = ["grep", "-n", "-I", "--no-color", "--null", "--untracked",
            *([] if regex else ["-F"]), "-e", pattern, "--", *([rel] if rel else [])]
    ran = await _git(name, repo, args)
    if ran.returncode not in (0, 1) and not ran.cut:
        raise _failed(ran, "git grep")
    matches = []
    lines = _text(ran.stdout).split("\n")
    if ran.cut and lines:
        lines.pop()
    for line in lines:
        parts = line.split("\0", 2)
        if len(parts) == 3 and parts[1].isdigit():
            matches.append({"path": parts[0], "line": int(parts[1]), "text": parts[2][:500]})
    return {"repo": repo, "pattern": pattern, "path": rel, "matches": matches[:limit],
            "cut": ran.cut or len(matches) > limit}


# file_get's reader, run inside the container with its arguments passed positionally
# ($1 repo, $2 path, $3 offset, $4 limit), so nothing the caller gave is ever parsed
# as shell. The path is checked twice: as written, with `..` folded but no symlink
# followed (so a path outside the repository is refused whether or not it exists),
# and resolved (so a symlink inside the repository pointing out of it is refused).
FILE_GET_SCRIPT = r"""
root=$(realpath -e -- "$1") || exit 10
case "$2" in /*) p=$2 ;; *) p=$root/$2 ;; esac
lex=$(realpath -m -s -- "$p") || exit 12
case "$lex" in "$root"|"$root"/*) ;; *) exit 12 ;; esac
real=$(realpath -e -- "$p") || exit 11
case "$real" in "$root"|"$root"/*) ;; *) exit 12 ;; esac
[ -d "$real" ] && exit 13
[ -f "$real" ] || exit 14
size=$(stat -c %s -- "$real") || exit 15
printf '%s\n%s\n' "$real" "$size"
tail -c +"$(( $3 + 1 ))" -- "$real" | head -c "$4"
"""


def file_get_argv(name: str, repo: str, path: str, offset: int, limit: int
                  ) -> tuple[list[str], str | None]:
    inner = ["sh", "-c", FILE_GET_SCRIPT, "sh", repo, path, str(offset), str(limit)]
    argv, cwd = in_session(name, repo, inner)
    return argv, cwd


def _decode_window(data: bytes) -> tuple[str, str, int]:
    """(encoding, content, bytes used): utf-8 when the window is text, with a multibyte
    character cut at the window's end left for the next call; else base64."""
    for trim in range(0, 4):
        part = data[: len(data) - trim] if trim else data
        try:
            return "utf-8", part.decode("utf-8"), len(part)
        except UnicodeDecodeError:
            continue
    return "base64", base64.b64encode(data).decode("ascii"), len(data)


_FILE_GET_EXITS = {
    10: ("not_found", "the session's repository {repo} is not there"),
    11: ("not_found", "there is no file '{path}' in the session's repository"),
    12: ("outside_repo", "'{path}' is outside the session's repository ({repo})"),
    13: ("invalid_argument", "'{path}' is a directory; file_list lists one"),
    14: ("invalid_argument", "'{path}' is not a regular file"),
}


async def read_file(name: str, repo: str, path: str, *, offset: int = 0,
                    limit: int = FILE_DEFAULT_LIMIT) -> dict[str, Any]:
    """One window of a file inside the repository."""
    if not path or not path.strip():
        raise RepoRefusal("invalid_argument", "path is required")
    if offset < 0:
        raise RepoRefusal("invalid_argument", "offset must be 0 or more")
    if not 1 <= limit <= FILE_MAX_LIMIT:
        raise RepoRefusal("invalid_argument", f"limit must be between 1 and {FILE_MAX_LIMIT}")
    argv, cwd = file_get_argv(name, repo, path, offset, limit)
    ran = await run_capped(argv, cwd=cwd, cap=limit + 8192)
    if ran.returncode in _FILE_GET_EXITS:
        code, text = _FILE_GET_EXITS[ran.returncode]
        raise RepoRefusal(code, text.format(path=path, repo=repo))
    if ran.returncode != 0:
        raise RepoRefusal("command_failed", f"reading '{path}' failed: "
                          f"{ran.stderr[:300] or f'exit {ran.returncode}'}")
    first, _, rest = ran.stdout.partition(b"\n")
    size_line, _, body = rest.partition(b"\n")
    resolved = first.decode("utf-8", errors="replace")
    size = int(size_line or b"0")
    encoding, content, used = _decode_window(body[:limit])
    next_offset = offset + used
    return {"path": resolved, "size": size, "offset": offset, "returned": used,
            "more": next_offset < size, "next_offset": next_offset if next_offset < size else None,
            "encoding": encoding, "content": content}
