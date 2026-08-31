import httpx
from fastapi.testclient import TestClient

from supervisor import create_app


class FakeProcessManager:
    def __init__(self):
        self.running = False
        self.starts = 0
        self.stops = 0

    async def ensure_started(self):
        self.running = True
        self.starts += 1

    async def stop(self):
        was_running = self.running
        self.running = False
        self.stops += 1
        return was_running


def test_proxy_starts_backend_lazily_and_release_stops_it():
    manager = FakeProcessManager()

    def upstream(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/release_task"
        return httpx.Response(200, json={"code": 200, "data": {"task_id": "one"}})

    upstream_client = httpx.AsyncClient(
        base_url="http://ace-backend.test",
        transport=httpx.MockTransport(upstream),
    )
    with TestClient(create_app(manager, upstream_client)) as client:
        assert client.get("/health").json() == {"status": "ok", "loaded": False}
        response = client.post("/release_task", json={"prompt": "jazz"})
        assert response.json()["data"]["task_id"] == "one"
        assert manager.starts == 1
        assert client.post("/api/gpu/release").json() == {"released": True}
        assert manager.stops == 1
