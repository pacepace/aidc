"""Tests for aidc_mcp.resources.

The audit resources read the session's audit dir where it is, in its audit sidecar (on Docker
a host folder this server does not mount, on Kubernetes a volume claim). These tests run the
real in-sidecar scripts against a folder here, and hold the path-traversal guard on the
audit-file resource: the security boundary that stops `{filename}` from escaping the
session's audit dir.
"""
import json
import subprocess

import pytest

from aidc_mcp import backend, resources, session_facts

# --- resource wiring ---------------------------------------------------------

def _fn(uri: str):
    """The reader the server calls for `uri` (a resource's URI or a template's)."""
    return {getattr(r, "uri", None) or r.uri_template: r.reader
            for r in resources.all_resources()}[uri]


AUDIT_FILE = "aidc://sessions/{name}/audit/{filename}"
AUDIT_LIST = "aidc://sessions/{name}/audit"


def _sidecar(monkeypatch, audit_dir, seen=None):
    """The audit sidecar, played here: an exec runs its script against `audit_dir` in place
    of the sidecar's mount; the mount lookup answers with `audit_dir`."""
    def run(argv):
        if seen is not None:
            seen.append(argv)
        if "sh" in argv:
            inner = argv[argv.index("sh"):]
            inner = [str(audit_dir) if a == session_facts.AUDIT_MOUNT else a for a in inner]
            return subprocess.run(inner, capture_output=True, check=False)
        return subprocess.CompletedProcess(argv, 0, f"{audit_dir}\n".encode(), b"")
    monkeypatch.setattr(resources, "_backend_run", run)


class TestAuditFileTraversalGuard:
    def _setup(self, tmp_path, monkeypatch):
        audit = tmp_path / "audit"
        audit.mkdir()
        _sidecar(monkeypatch, audit)
        return audit

    async def test_reads_file_inside_audit_dir(self, tmp_path, monkeypatch):
        audit = self._setup(tmp_path, monkeypatch)
        (audit / "events.log").write_text("hello", encoding="utf-8")
        out = json.loads(await _fn(AUDIT_FILE)("proj", "events.log"))
        assert out["content"] == "hello"
        assert out["path"].endswith("/audit/events.log")

    async def test_rejects_parent_traversal(self, tmp_path, monkeypatch):
        self._setup(tmp_path, monkeypatch)
        (tmp_path / "secret").write_text("TOPSECRET", encoding="utf-8")
        out = json.loads(await _fn(AUDIT_FILE)("proj", "../secret"))
        assert out == {"error": "path traversal denied"}

    async def test_rejects_deep_traversal(self, tmp_path, monkeypatch):
        self._setup(tmp_path, monkeypatch)
        out = json.loads(await _fn(AUDIT_FILE)("proj", "../../../../etc/passwd"))
        assert out["error"] == "path traversal denied"

    async def test_rejects_a_symlink_out_of_the_dir(self, tmp_path, monkeypatch):
        audit = self._setup(tmp_path, monkeypatch)
        (tmp_path / "secret").write_text("TOPSECRET", encoding="utf-8")
        (audit / "link.log").symlink_to(tmp_path / "secret")
        out = json.loads(await _fn(AUDIT_FILE)("proj", "link.log"))
        assert out == {"error": "path traversal denied"}

    async def test_missing_file_inside_dir(self, tmp_path, monkeypatch):
        self._setup(tmp_path, monkeypatch)
        out = json.loads(await _fn(AUDIT_FILE)("proj", "nope.log"))
        assert out["error"] == "file not found"

    async def test_binary_file_reports_placeholder(self, tmp_path, monkeypatch):
        audit = self._setup(tmp_path, monkeypatch)
        (audit / "blob.bin").write_bytes(b"\xff\xfe\x00")
        out = json.loads(await _fn(AUDIT_FILE)("proj", "blob.bin"))
        assert "binary" in out["content"]

    async def test_no_audit_dir(self, tmp_path, monkeypatch):
        _sidecar(monkeypatch, tmp_path / "not-there")
        out = json.loads(await _fn(AUDIT_FILE)("proj", "events.log"))
        assert out["error"] == "audit dir not found"


class TestAuditListing:
    async def test_lists_files(self, tmp_path, monkeypatch):
        audit = tmp_path / "audit"
        audit.mkdir()
        (audit / "a.log").write_text("x", encoding="utf-8")
        (audit / ".hidden").write_text("yy", encoding="utf-8")
        (audit / "sub").mkdir()
        _sidecar(monkeypatch, audit)
        out = json.loads(await _fn(AUDIT_LIST)("proj"))
        names = {f["name"]: f for f in out["files"]}
        assert names["a.log"]["size"] == 1 and names["a.log"]["is_dir"] is False
        assert names[".hidden"]["size"] == 2
        assert names["sub"]["is_dir"] is True
        assert out["audit_dir"] == str(audit)

    async def test_missing_dir(self, tmp_path, monkeypatch):
        _sidecar(monkeypatch, tmp_path / "not-there")
        out = json.loads(await _fn(AUDIT_LIST)("proj"))
        assert out["error"] == "audit dir not found"


@pytest.mark.parametrize("kind", ["docker", "kubernetes"])
async def test_the_audit_dir_is_read_in_the_sessions_audit_sidecar(kind, tmp_path,
                                                                    monkeypatch):
    """On both backends the read is an exec in the session's own audit sidecar, which
    mounts the audit dir; nothing reads a path on this server's own filesystem."""
    monkeypatch.setenv(backend.KIND_ENV, kind)
    monkeypatch.setenv(backend.NAMESPACE_ENV, "aidc-u-alice")
    audit = tmp_path / "audit"
    audit.mkdir()
    (audit / "events.log").write_text("hi", encoding="utf-8")
    seen = []
    _sidecar(monkeypatch, audit, seen)
    out = json.loads(await _fn(AUDIT_FILE)("proj", "events.log"))
    assert out["content"] == "hi"
    exec_argv = seen[0]
    sidecar = backend.target("proj", backend.ROLE_AUDIT)
    if kind == "docker":
        assert exec_argv[:3] == ["docker", "exec", sidecar]
    else:
        assert exec_argv[:7] == ["kubectl", "-n", "aidc-u-alice", "exec",
                                 "--pod-running-timeout=10s", "deployment/proj-proxy", "-c"]
        assert exec_argv[7] == "audit"


class TestRunFailsafe:
    def test_run_swallows_subprocess_errors(self, monkeypatch):
        # _run must never raise; a failing/absent CLI yields "".
        def boom(*a, **k):
            raise OSError("no such binary")
        monkeypatch.setattr(resources.subprocess, "run", boom)
        assert resources._run(["list"]) == ""
