"""Tests for the bearer-auth ASGI middleware (the server's security boundary).

Drives BearerAuthMiddleware.__call__ directly with hand-built ASGI scopes so the
constant-time token compare, the 401 rejections, the token-file loading errors,
and the non-http pass-through are pinned without a running server.
"""
import pytest

from aidc_mcp import auth
from aidc_mcp.auth import BearerAuthMiddleware


class _InnerApp:
    """Minimal downstream ASGI app: records that it was reached and 200s."""

    def __init__(self):
        self.called = False

    async def __call__(self, scope, receive, send):
        self.called = True
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})


class _Send:
    def __init__(self):
        self.messages = []

    async def __call__(self, message):
        self.messages.append(message)


async def _receive():
    return {"type": "http.request", "body": b"", "more_body": False}


def _status(send: _Send):
    for m in send.messages:
        if m["type"] == "http.response.start":
            return m["status"]
    return None


def _http_scope(authorization=None, scope_type="http"):
    headers = []
    if authorization is not None:
        headers.append((b"authorization", authorization.encode()))
    return {
        "type": scope_type,
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "server": ("testserver", 80),
        "path": "/mcp",
        "query_string": b"",
        "headers": headers,
        "client": ("10.0.0.9", 4444),
    }


@pytest.fixture
def token_file(tmp_path, monkeypatch):
    p = tmp_path / "mcp-token"
    p.write_text("s3cr3t-token\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", p)
    return p


async def test_valid_token_passes_through(token_file):
    inner = _InnerApp()
    mw = BearerAuthMiddleware(inner)
    send = _Send()
    await mw(_http_scope("Bearer s3cr3t-token"), _receive, send)
    assert inner.called is True
    assert _status(send) == 200


async def test_valid_token_tolerates_surrounding_whitespace(token_file):
    # The presented token is .strip()-ed before the constant-time compare.
    inner = _InnerApp()
    mw = BearerAuthMiddleware(inner)
    send = _Send()
    await mw(_http_scope("Bearer   s3cr3t-token  "), _receive, send)
    assert inner.called is True


async def test_no_bearer_prefix_is_401(token_file):
    inner = _InnerApp()
    mw = BearerAuthMiddleware(inner)
    send = _Send()
    await mw(_http_scope("Token s3cr3t-token"), _receive, send)
    assert _status(send) == 401
    assert inner.called is False


async def test_missing_authorization_header_is_401(token_file):
    inner = _InnerApp()
    mw = BearerAuthMiddleware(inner)
    send = _Send()
    await mw(_http_scope(None), _receive, send)
    assert _status(send) == 401
    assert inner.called is False


async def test_bad_token_is_401(token_file):
    inner = _InnerApp()
    mw = BearerAuthMiddleware(inner)
    send = _Send()
    await mw(_http_scope("Bearer wrong-token"), _receive, send)
    assert _status(send) == 401
    assert inner.called is False


async def test_non_http_scope_bypasses_auth(token_file):
    # lifespan / websocket scopes are passed straight through (no token check).
    inner = _InnerApp()
    mw = BearerAuthMiddleware(inner)
    send = _Send()
    await mw(_http_scope("Bearer wrong-token", scope_type="lifespan"), _receive, send)
    assert inner.called is True  # reached despite an invalid token


def test_missing_token_file_raises_runtime_error(tmp_path, monkeypatch):
    monkeypatch.setattr(auth, "_TOKEN_PATH", tmp_path / "does-not-exist")
    with pytest.raises(RuntimeError, match="not found"):
        BearerAuthMiddleware(_InnerApp())


def test_empty_token_file_raises_runtime_error(tmp_path, monkeypatch):
    p = tmp_path / "mcp-token"
    p.write_text("   \n", encoding="utf-8")  # whitespace-only -> empty after strip
    monkeypatch.setattr(auth, "_TOKEN_PATH", p)
    with pytest.raises(RuntimeError, match="empty"):
        BearerAuthMiddleware(_InnerApp())
