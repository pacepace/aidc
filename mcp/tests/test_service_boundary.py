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

FORBIDDEN_PACKAGES = {"mcp", "fastmcp"}
# The MCP face of aidc: the service must not reach back into it.
ADAPTER_MODULES = {"aidc_mcp.tools", "aidc_mcp.server", "aidc_mcp.resources",
                   "aidc_mcp.disconnect", "aidc_mcp.publish"}


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
    # The fresh-interpreter check above can tell: the tools module does load the SDK.
    assert "mcp" in _modules_loaded_by_importing(["aidc_mcp.tools"])
