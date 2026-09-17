"""The aidc-mcp entry point's startup hook: persisted send queues resume on start."""
from aidc_mcp import server, tools


async def test_lifespan_start_resumes_send_queues_once_and_passes_through(monkeypatch):
    fired = []
    monkeypatch.setattr(tools, "_fire", lambda coro: (fired.append(coro), coro.close()))
    seen = []

    async def app(scope, receive, send):
        seen.append(scope["type"])

    wrapped = server.ResumeQueuesOnStartup(app)
    await wrapped({"type": "lifespan"}, None, None)
    await wrapped({"type": "http"}, None, None)
    await wrapped({"type": "lifespan"}, None, None)

    assert len(fired) == 1
    assert seen == ["lifespan", "http", "lifespan"]
