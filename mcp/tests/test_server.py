"""The aidc-mcp entry point's startup hook: persisted send queues and webhooks resume."""
from aidc_mcp import server, tools


async def test_lifespan_start_resumes_once_and_passes_through(monkeypatch):
    fired = []
    monkeypatch.setattr(tools, "_fire", fired.append)
    resumed_with = []

    async def resume(mcp_app):
        resumed_with.append(mcp_app)

    monkeypatch.setattr(tools, "resume_on_startup", resume)
    seen = []

    async def app(scope, receive, send):
        seen.append(scope["type"])

    mcp_app = object()
    wrapped = server.ResumeOnStartup(app, mcp_app)
    await wrapped({"type": "lifespan"}, None, None)
    await wrapped({"type": "http"}, None, None)
    await wrapped({"type": "lifespan"}, None, None)

    assert len(fired) == 1
    assert seen == ["lifespan", "http", "lifespan"]
    await fired[0]
    assert resumed_with == [mcp_app]


async def test_startup_resumes_queues_before_webhooks(monkeypatch):
    order = []

    async def queues():
        order.append("queues")

    async def watchers(app):
        order.append("watchers")

    monkeypatch.setattr(tools, "resume_send_queues", queues)
    monkeypatch.setattr(tools, "resume_watchers", watchers)
    await tools.resume_on_startup(object())
    assert order == ["queues", "watchers"]
