"""Tests for aidc_mcp.resources.

Covers the shared `aidc status` audit-dir parser (used by both the resources here
and tools.audit_get) and the path-traversal guard on the audit-file resource — the
security boundary that stops `{filename}` from escaping the session's audit dir.
"""
import json
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from aidc_mcp import resources
from aidc_mcp.resources import parse_audit_dir

# --- parse_audit_dir ---------------------------------------------------------

class TestParseAuditDir:
    def test_parses_audit_colon_line(self):
        assert parse_audit_dir("name: proj\naudit: /var/audit/proj\nfoo: bar") == \
            Path("/var/audit/proj")

    def test_parses_padded_audit_line(self):
        # `aidc status` prints the value column-padded: `audit:      /path`.
        assert str(parse_audit_dir("== session ==\naudit:      /var/audit/proj\n")) == \
            "/var/audit/proj"

    def test_case_insensitive(self):
        # tools.audit_get used to match case-sensitively; the shared helper is
        # case-insensitive so a header-case change in the CLI can't break it.
        assert str(parse_audit_dir("AUDIT: /upper/case")) == "/upper/case"
        assert str(parse_audit_dir("Audit:  /mixed")) == "/mixed"

    def test_returns_none_when_absent(self):
        assert parse_audit_dir("health: ok\ntaint: none") is None

    def test_returns_none_on_empty(self):
        assert parse_audit_dir("") is None

    def test_strips_stray_colon_and_whitespace(self):
        # `audit:   /p` -> split gives ["audit:", "/p"]; lstrip(':') on the value
        # is a no-op here, but a value like `: /p` must not keep the leading colon.
        assert str(parse_audit_dir("audit:  /padded  ")) == "/padded"


# --- resource wiring ---------------------------------------------------------

def _fn(uri: str):
    app = FastMCP("t")
    resources.register(app)
    rm = app._resource_manager
    if uri in rm._templates:
        return rm._templates[uri].fn
    return rm._resources[uri].fn


AUDIT_FILE = "aidc://sessions/{name}/audit/{filename}"
AUDIT_LIST = "aidc://sessions/{name}/audit"


class TestAuditFileTraversalGuard:
    def _setup(self, tmp_path, monkeypatch):
        audit = tmp_path / "audit"
        audit.mkdir()
        monkeypatch.setattr(resources, "_run", lambda args: f"audit: {audit}\n")
        return audit

    def test_reads_file_inside_audit_dir(self, tmp_path, monkeypatch):
        audit = self._setup(tmp_path, monkeypatch)
        (audit / "events.log").write_text("hello", encoding="utf-8")
        out = json.loads(_fn(AUDIT_FILE)("proj", "events.log"))
        assert out["content"] == "hello"
        assert out["path"].endswith("/audit/events.log")

    def test_rejects_parent_traversal(self, tmp_path, monkeypatch):
        self._setup(tmp_path, monkeypatch)
        (tmp_path / "secret").write_text("TOPSECRET", encoding="utf-8")
        out = json.loads(_fn(AUDIT_FILE)("proj", "../secret"))
        assert out == {"error": "path traversal denied"}

    def test_rejects_deep_traversal(self, tmp_path, monkeypatch):
        self._setup(tmp_path, monkeypatch)
        out = json.loads(_fn(AUDIT_FILE)("proj", "../../../../etc/passwd"))
        assert out["error"] == "path traversal denied"

    def test_missing_file_inside_dir(self, tmp_path, monkeypatch):
        self._setup(tmp_path, monkeypatch)
        out = json.loads(_fn(AUDIT_FILE)("proj", "nope.log"))
        assert out["error"] == "file not found"

    def test_binary_file_reports_placeholder(self, tmp_path, monkeypatch):
        audit = self._setup(tmp_path, monkeypatch)
        (audit / "blob.bin").write_bytes(b"\xff\xfe\x00")
        out = json.loads(_fn(AUDIT_FILE)("proj", "blob.bin"))
        assert "binary" in out["content"]

    def test_no_audit_dir(self, tmp_path, monkeypatch):
        monkeypatch.setattr(resources, "_run", lambda args: "health: ok\n")
        out = json.loads(_fn(AUDIT_FILE)("proj", "events.log"))
        assert out["error"] == "audit dir not found"


class TestAuditListing:
    def test_lists_files(self, tmp_path, monkeypatch):
        audit = tmp_path / "audit"
        audit.mkdir()
        (audit / "a.log").write_text("x", encoding="utf-8")
        (audit / "sub").mkdir()
        monkeypatch.setattr(resources, "_run", lambda args: f"audit: {audit}\n")
        out = json.loads(_fn(AUDIT_LIST)("proj"))
        names = {f["name"]: f for f in out["files"]}
        assert names["a.log"]["size"] == 1 and names["a.log"]["is_dir"] is False
        assert names["sub"]["is_dir"] is True

    def test_missing_dir(self, tmp_path, monkeypatch):
        monkeypatch.setattr(resources, "_run", lambda args: "no audit here")
        out = json.loads(_fn(AUDIT_LIST)("proj"))
        assert out["error"] == "audit dir not found"


class TestRunFailsafe:
    def test_run_swallows_subprocess_errors(self, monkeypatch):
        # _run must never raise; a failing/absent CLI yields "".
        def boom(*a, **k):
            raise OSError("no such binary")
        monkeypatch.setattr(resources.subprocess, "run", boom)
        assert resources._run(["list"]) == ""
