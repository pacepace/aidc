"""The aidc-mcp entry point's startup: the server starts, then persisted send queues and
webhooks resume, once."""
import pytest
from starlette.testclient import TestClient

from aidc_mcp import auth, server
from aidc_mcp.service import common as com
from aidc_mcp.service import delivery as dlv
from aidc_mcp.service import sending as snd


@pytest.fixture
def token_file(tmp_path, monkeypatch):
    path = tmp_path / "mcp-token"
    path.write_text("t\n", encoding="utf-8")
    monkeypatch.setattr(auth, "_TOKEN_PATH", path)
    return path


def test_the_app_starts_resumes_once_and_stops(token_file, monkeypatch):
    fired = []
    monkeypatch.setattr(com, "fire", fired.append)
    face = server.Face()
    with TestClient(server.build_app(face)):
        assert len(fired) == 1          # the resume, started with the server
    for coro in fired:
        coro.close()


async def test_a_failing_queue_resume_does_not_stop_webhooks_resuming(monkeypatch):
    resumed = []

    async def queues():
        raise OSError("disk full")

    async def watches(on_resumed):
        resumed.append(True)

    monkeypatch.setattr(snd, "resume_send_queues", queues)
    monkeypatch.setattr(dlv, "resume_watches", watches)
    await server.Face().resume()
    assert resumed == [True]


async def test_startup_resumes_queues_before_webhooks(monkeypatch):
    order = []

    async def queues():
        order.append("queues")

    async def watches(on_resumed):
        order.append("watchers")

    monkeypatch.setattr(snd, "resume_send_queues", queues)
    monkeypatch.setattr(dlv, "resume_watches", watches)
    await server.Face().resume()
    assert order == ["queues", "watchers"]


async def test_a_reopened_webhook_tells_the_clients_the_tool_list_changed(monkeypatch):
    face = server.Face()
    told = []

    async def announce():
        told.append(True)
    monkeypatch.setattr(face, "announce", announce)

    async def watches(on_resumed):
        on_resumed()

    async def queues():
        return None
    monkeypatch.setattr(snd, "resume_send_queues", queues)
    monkeypatch.setattr(dlv, "resume_watches", watches)
    fired = []
    monkeypatch.setattr(com, "fire", fired.append)
    await face.resume()
    for coro in fired:
        await coro
    assert told == [True]

