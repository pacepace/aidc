"""The service package holds no MCP: aidc 2.0 serves the same service through 3tears tools
(docs/design-13-3tears-tools.md), so nothing in it may need the MCP SDK to import or run.
If one of these fails, an MCP type or the MCP adapters leaked into the service: take what
the transport knows (a Context, the app) as a plain callable instead, as `progress` and
`announce` do."""
import ast
import importlib
import importlib.util
import json
import pkgutil
import subprocess
import sys

import aidc_mcp.service as service

FORBIDDEN_PACKAGES = {"mcp", "fastmcp", "threetears"}
# aidc's tools and faces: the service must not reach back into them (TRS-13).
ADAPTER_MODULES = {"aidc_mcp.server", "aidc_mcp.resources", "aidc_mcp.publish",
                   "aidc_mcp.authz", "aidc_mcp.tearstools"}


def _service_modules():
    return [f"aidc_mcp.service.{m.name}" for m in pkgutil.iter_modules(service.__path__)]


def _imported(module_name):
    """Every module an import statement in `module_name`'s source names."""
    source = importlib.util.find_spec(module_name).origin
    tree = ast.parse(open(source, encoding="utf-8").read())
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out.update(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            out.add(node.module)
            out.update(f"{node.module}.{a.name}" for a in node.names)
    return out


def test_the_service_package_has_modules_to_check():
    # A rename of the package or its modules would make the checks below pass vacuously.
    assert {"aidc_mcp.service.state", "aidc_mcp.service.common"} <= set(_service_modules())


def test_no_service_module_imports_mcp_or_the_adapters():
    found = {}
    for name in ["aidc_mcp.service", *_service_modules()]:
        bad = sorted(m for m in _imported(name)
                     if m.split(".")[0] in FORBIDDEN_PACKAGES or m in ADAPTER_MODULES)
        if bad:
            found[name] = bad
    assert found == {}


def _modules_loaded_by_importing(names):
    """The top-level packages a fresh interpreter has loaded after importing `names`."""
    code = ("import json, sys\n"
            + "".join(f"import {n}\n" for n in names)
            + "print(json.dumps(sorted({m.split('.')[0] for m in sys.modules})))")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                         check=True)
    return set(json.loads(out.stdout))


def test_importing_the_whole_service_loads_no_mcp_package():
    """Transitively too: a core module the service imports must not pull the SDK in."""
    loaded = _modules_loaded_by_importing(_service_modules())
    assert loaded & FORBIDDEN_PACKAGES == set()


def test_the_import_check_sees_mcp_when_it_is_there():
    # The fresh-interpreter check above can tell: the face does load the SDK.
    assert "mcp" in _modules_loaded_by_importing(["aidc_mcp.server"])


def test_the_tools_load_no_mcp_package():
    """TRS-18: the TearsTools stay free of MCP types, so another face (an HTTP API, the
    mesh) can serve the same instances without the MCP SDK."""
    tools = ["aidc_mcp.tearstools", *(f"aidc_mcp.tearstools.{m.name}" for m in
                                      pkgutil.iter_modules(
                                          importlib.import_module("aidc_mcp.tearstools").__path__))]
    assert "mcp" not in _modules_loaded_by_importing(tools)


def _package_modules():
    import aidc_mcp
    import aidc_mcp.tearstools as tearstools
    return ["aidc_mcp", *(f"aidc_mcp.{m.name}" for m in pkgutil.iter_modules(aidc_mcp.__path__)),
            *_service_modules(),
            *(f"aidc_mcp.tearstools.{m.name}" for m in pkgutil.iter_modules(tearstools.__path__))]


def test_no_module_imports_log_event_by_name():
    """Every module logs through `audit.log_event`, the one binding, so tests/logs.py's single
    patch catches every event: a `from aidc_mcp.audit import log_event` would hold a second
    binding the patch misses, and a test asserting an event is absent would pass wrongly."""
    by_name = sorted(name for name in _package_modules()
                     if "aidc_mcp.audit.log_event" in _imported(name))
    assert by_name == []


async def test_the_log_event_patch_catches_auth_and_session_facts(monkeypatch):
    """The two modules outside tools and the service that log are reached by it too: an
    auth rejection and an unreadable taint flag, each logged by its own module."""
    from aidc_mcp import auth, session_facts
    from tests.logs import patch_log_event
    seen = []
    patch_log_event(monkeypatch, lambda kind, **fields: seen.append(kind))

    async def unreadable(name):
        raise session_facts.TaintUnknown("probe")
    monkeypatch.setattr(session_facts, "read_taint", unreadable)
    assert await session_facts.taint_or_none("s1") is None

    async def app(scope, receive, send):
        raise AssertionError("a request with no bearer reaches the app")
    sent = []

    async def receive():
        return {"type": "http.request", "body": b""}

    async def send(message):
        sent.append(message)
    scope = {"type": "http", "method": "GET", "path": "/mcp", "headers": [],
             "query_string": b"", "client": ("127.0.0.1", 1), "server": ("x", 80),
             "scheme": "http", "root_path": ""}
    monkeypatch.setattr(auth, "load_token", lambda: "t")
    await auth.BearerAuthMiddleware(app)(scope, receive, send)
    assert seen == ["session_taint_unreadable", "auth_reject"]
