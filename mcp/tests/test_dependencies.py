"""TRS-02: the server runs on the MCP SDK 2.x only, and on one 3tears minor.

The 3tears family has no compatibility across minor versions, so two of its packages from
different minors (or, while aidc builds on an unreleased branch, from different commits) can
import fine and still disagree about a type or a protocol rule. These read what the lock
resolved, since that is what the image installs (`uv sync --frozen`)."""
import pathlib
import re
import tomllib

MCP_DIR = pathlib.Path(__file__).resolve().parent.parent


def _lock():
    return tomllib.loads((MCP_DIR / "uv.lock").read_text(encoding="utf-8"))


def _pyproject():
    return tomllib.loads((MCP_DIR / "pyproject.toml").read_text(encoding="utf-8"))


def _packages(lock):
    return {p["name"]: p for p in lock["package"]}


def _major_minor(version):
    major, minor = version.split(".")[:2]
    return int(major), int(minor)


def _git_rev(package):
    """The commit a git-sourced lock entry resolved to (the part after '#'), or None."""
    git = package.get("source", {}).get("git")
    return git.rsplit("#", 1)[1] if git and "#" in git else None


def _tears_packages(packages):
    return {n: p for n, p in packages.items() if n == "3tears" or n.startswith("3tears-")}


def test_the_lock_resolves_the_mcp_sdk_to_2_x():
    # a 1.x SDK has another server registration API; 3tears-mcp no longer supports it
    version = _packages(_lock())["mcp"]["version"]
    assert _major_minor(version)[0] == 2, f"mcp resolved to {version}, not 2.x"


def test_the_lock_holds_the_3tears_packages_local_mode_needs():
    names = set(_tears_packages(_packages(_lock())))
    assert {"3tears-mcp", "3tears-tool-contract", "3tears-tool-schema",
            "3tears-observe"} <= names


def test_every_3tears_package_in_the_lock_is_on_one_minor():
    tears = _tears_packages(_packages(_lock()))
    minors = {n: _major_minor(p["version"]) for n, p in tears.items()}
    assert len(set(minors.values())) == 1, f"3tears packages on different minors: {minors}"


def test_every_git_sourced_3tears_package_comes_from_one_commit():
    # one package from another commit would be the two-minors problem inside one minor
    tears = _tears_packages(_packages(_lock()))
    revs = {n: _git_rev(p) for n, p in tears.items() if _git_rev(p)}
    assert len(set(revs.values())) <= 1, f"3tears packages from different commits: {revs}"
    # a git-sourced package beside a registry one would mix the branch with a release
    if revs:
        assert set(revs) == set(tears), (
            f"some 3tears packages are not from the branch commit: {set(tears) - set(revs)}")


def test_every_3tears_dependency_is_pinned_to_one_minor_range():
    # `>=0.N,<0.N+1` for each: a re-lock cannot move one package to the next minor alone
    deps = [d for d in _pyproject()["project"]["dependencies"] if d.startswith("3tears")]
    assert deps
    ranges = set()
    for dep in deps:
        m = re.fullmatch(r"(3tears[\w-]*)(\[[\w,-]+\])?>=0\.(\d+),<0\.(\d+)", dep.replace(" ", ""))
        assert m, f"{dep!r} is not pinned as >=0.N,<0.N+1"
        assert int(m.group(4)) == int(m.group(3)) + 1, f"{dep!r} spans more than one minor"
        ranges.add(m.group(3))
    assert len(ranges) == 1, f"3tears dependencies pinned to different minors: {deps}"


def test_the_git_sources_name_one_full_commit():
    # a branch name or short sha would let the lock and a fresh resolve disagree
    sources = _pyproject()["tool"]["uv"]["sources"]
    revs = {n: s.get("rev") for n, s in sources.items() if n.startswith("3tears")}
    assert revs
    assert len(set(revs.values())) == 1, f"3tears sources on different revs: {revs}"
    assert all(rev and re.fullmatch(r"[0-9a-f]{40}", rev) for rev in revs.values()), revs


def test_the_mesh_extra_is_declared():
    # TRS-17: mesh mode's dependencies live behind an extra, so local mode stays light
    assert "mesh" in _pyproject()["project"]["optional-dependencies"]


def test_local_mode_resolves_none_of_the_platform():
    # TRS-17: the local server needs no NATS, Postgres driver, LangGraph or LangChain; a 3tears
    # package that started pulling one in would make every aidc install carry it
    names = set(_packages(_lock()))
    heavy = {n for n in names
             if n in {"nats-py", "asyncpg", "psycopg", "psycopg2", "psycopg-binary", "3tears",
                      "3tears-nats", "3tears-agent-tools", "3tears-registry"}
             or n.startswith(("langgraph", "langchain"))}
    assert not heavy, f"the lock resolves platform packages: {sorted(heavy)}"
