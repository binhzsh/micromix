from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Protocol

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response


class ProcessControlling(Protocol):
    running: bool

    async def ensure_started(self) -> None: ...

    async def stop(self) -> bool: ...


class ACEProcessManager:
    def __init__(self, backend_url: str = "http://127.0.0.1:18001") -> None:
        self.backend_url = backend_url
        self.process: asyncio.subprocess.Process | None = None
        self.lock = asyncio.Lock()

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.returncode is None

    async def ensure_started(self) -> None:
        async with self.lock:
            if self.running:
                return
            await asyncio.to_thread(self._ensure_pinned_models)
            environment = dict(os.environ)
            environment["ACESTEP_NO_INIT"] = "true"
            environment["ACESTEP_INIT_LLM"] = "true"
            self.process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "acestep.api_server",
                "--host",
                "127.0.0.1",
                "--port",
                "18001",
                "--no-init",
                "--init-llm",
                env=environment,
            )
            async with httpx.AsyncClient(timeout=2) as client:
                for _ in range(120):
                    if not self.running:
                        raise RuntimeError("ACE-Step backend exited during startup")
                    try:
                        response = await client.get(f"{self.backend_url}/health")
                        if response.status_code == 200:
                            return
                    except httpx.HTTPError:
                        pass
                    await asyncio.sleep(1)
            await self.stop()
            raise RuntimeError("ACE-Step backend did not become ready")

    @staticmethod
    def _ensure_pinned_models() -> None:
        from huggingface_hub import snapshot_download

        checkpoint_root = Path(os.getenv("ACESTEP_CHECKPOINT_DIR", "/app/checkpoints"))
        models = (
            (
                "ACE-Step/acestep-v15-xl-turbo",
                "acestep-v15-xl-turbo",
                os.getenv(
                    "ACESTEP_TURBO_REVISION",
                    "d4a0b288b83ebb7e25a8c0b32c573c22e134e8ee",
                ),
            ),
            (
                "ACE-Step/acestep-v15-xl-sft",
                "acestep-v15-xl-sft",
                os.getenv(
                    "ACESTEP_QUALITY_REVISION",
                    "d06de46b4622f781cf07f4a013a67d591ca52819",
                ),
            ),
            (
                "ACE-Step/acestep-5Hz-lm-4B",
                "acestep-5Hz-lm-4B",
                os.getenv(
                    "ACESTEP_LM_REVISION",
                    "0a3ec94b557aea7d508da38b31cfe7341f6ff737",
                ),
            ),
        )
        checkpoint_root.mkdir(parents=True, exist_ok=True)
        for repo_id, directory, revision in models:
            target = checkpoint_root / directory
            marker = target / ".micromix-revision"
            if marker.exists() and marker.read_text().strip() == revision:
                continue
            snapshot_download(
                repo_id=repo_id,
                revision=revision,
                local_dir=target,
                token=os.getenv("HF_TOKEN") or None,
            )
            marker.write_text(f"{revision}\n")

    async def stop(self) -> bool:
        async with self.lock:
            if not self.running:
                self.process = None
                return False
            process, self.process = self.process, None
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=30)
            except TimeoutError:
                process.kill()
                await process.wait()
            return True


def create_app(
    manager: ProcessControlling | None = None,
    upstream_client: httpx.AsyncClient | None = None,
) -> FastAPI:
    app = FastAPI(title="Micromix ACE-Step Supervisor")
    process_manager = manager or ACEProcessManager()
    client = upstream_client or httpx.AsyncClient(
        base_url="http://127.0.0.1:18001",
        timeout=1200,
    )
    known_task_ids: set[str] = set()

    async def proxy(method: str, path: str, request: Request) -> Response:
        try:
            await process_manager.ensure_started()
            payload = await request.body()
            upstream = await client.request(
                method,
                path,
                params=request.query_params,
                content=payload or None,
                headers={"content-type": request.headers.get("content-type", "application/json")},
            )
        except Exception as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc
        headers = {}
        if disposition := upstream.headers.get("content-disposition"):
            headers["content-disposition"] = disposition
        return Response(
            content=upstream.content,
            status_code=upstream.status_code,
            media_type=upstream.headers.get("content-type", "application/json").split(";", 1)[0],
            headers=headers,
        )

    @app.get("/health")
    async def health() -> dict[str, str | bool]:
        return {"status": "ok", "loaded": process_manager.running}

    @app.post("/release_task")
    async def release_task(request: Request) -> Response:
        response = await proxy("POST", "/release_task", request)
        if response.status_code < 400:
            try:
                payload = json.loads(response.body)
                task_id = payload.get("data", {}).get("task_id")
                if task_id:
                    known_task_ids.add(str(task_id))
            except (AttributeError, TypeError, ValueError):
                pass
        return response

    @app.post("/query_result")
    async def query_result(request: Request) -> Response:
        try:
            request_payload = await request.json()
        except (json.JSONDecodeError, ValueError):
            request_payload = {}
        task_ids = request_payload.get("task_id_list", [])
        if isinstance(task_ids, str):
            try:
                task_ids = json.loads(task_ids)
            except (json.JSONDecodeError, TypeError):
                task_ids = []
        if not isinstance(task_ids, list):
            task_ids = []

        if not process_manager.running:
            return JSONResponse(
                {
                    "code": 200,
                    "data": [
                        {
                            "task_id": str(task_id),
                            "status": 3,
                            "result": "[]",
                        }
                        for task_id in task_ids
                    ],
                }
            )

        response = await proxy("POST", "/query_result", request)
        if response.status_code >= 400:
            return response
        try:
            payload = json.loads(response.body)
            for row in payload.get("data", []):
                task_id = str(row.get("task_id", ""))
                if (
                    task_id not in known_task_ids
                    and int(row.get("status", 0)) == 0
                    and row.get("result") == "[]"
                ):
                    row["status"] = 3
            return JSONResponse(payload, status_code=response.status_code)
        except (AttributeError, TypeError, ValueError):
            return response

    @app.get("/v1/audio")
    async def audio(request: Request) -> Response:
        return await proxy("GET", "/v1/audio", request)

    @app.post("/api/gpu/release")
    async def release_gpu() -> dict[str, bool]:
        released = await process_manager.stop()
        known_task_ids.clear()
        return {"released": released}

    return app


app = create_app()
