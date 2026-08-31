from __future__ import annotations

import json
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import httpx

from .coordinator import UpstreamResult


def _error_detail(response: httpx.Response) -> str:
    try:
        payload = response.json()
        return str(payload.get("detail") or payload.get("error") or response.text)
    except Exception:  # noqa: BLE001 - error formatting must not mask response
        return response.text or f"HTTP {response.status_code}"


class GPUClient:
    def __init__(self, base_url: str, *, client: httpx.AsyncClient | None = None):
        self.base_url = base_url.rstrip("/")
        self.client = client or httpx.AsyncClient(timeout=180)

    async def acquire(self, app: str, required_mib: int, wait_seconds: int) -> None:
        response = await self.client.post(
            f"{self.base_url}/acquire",
            json={
                "app": app,
                "required_mib": required_mib,
                "wait_seconds": wait_seconds,
            },
        )
        if response.status_code >= 400:
            raise RuntimeError(_error_detail(response))

    async def release(self, app: str) -> None:
        response = await self.client.post(f"{self.base_url}/release", json={"app": app})
        if response.status_code >= 400:
            raise RuntimeError(_error_detail(response))

    async def status(self) -> dict:
        try:
            response = await self.client.get(f"{self.base_url}/status")
            response.raise_for_status()
            payload = response.json()
            return {
                "status": "ready",
                "free_mib": payload.get("gpu", {}).get("free_mib"),
                "holders": payload.get("holders", []),
            }
        except Exception:  # noqa: BLE001 - health aggregation is best effort
            return {"status": "unreachable", "free_mib": None, "holders": []}

    async def aclose(self) -> None:
        await self.client.aclose()


class ACEClient:
    MODELS = {
        "turbo": ("acestep-v15-xl-turbo", 8),
        "quality": ("acestep-v15-xl-sft", 50),
    }

    def __init__(self, base_url: str, *, client: httpx.AsyncClient | None = None):
        self.base_url = base_url.rstrip("/")
        self.client = client or httpx.AsyncClient(timeout=1200)

    async def submit(self, parameters: dict) -> str:
        preset = parameters.get("preset", "turbo")
        model, steps = self.MODELS[preset]
        payload: dict = {
            "prompt": parameters["prompt"],
            "lyrics": parameters.get("lyrics", ""),
            "model": model,
            "inference_steps": steps,
            "thinking": True,
            "lm_model_path": "acestep-5Hz-lm-4B",
            "audio_format": "wav",
            "audio_duration": parameters.get("duration_seconds", 30),
        }
        if parameters.get("seed") is not None:
            payload["use_random_seed"] = False
            payload["seed"] = parameters["seed"]
        else:
            payload["use_random_seed"] = True
        for source, target in (
            ("bpm", "bpm"),
            ("key", "key_scale"),
            ("time_signature", "time_signature"),
        ):
            if parameters.get(source) is not None:
                payload[target] = parameters[source]

        response = await self.client.post(f"{self.base_url}/release_task", json=payload)
        if response.status_code >= 400:
            raise RuntimeError(_error_detail(response))
        wrapper = response.json()
        if wrapper.get("code") != 200 or not wrapper.get("data", {}).get("task_id"):
            raise RuntimeError(str(wrapper.get("error") or "ACE-Step rejected generation"))
        return str(wrapper["data"]["task_id"])

    async def health(self) -> str:
        try:
            response = await self.client.get(f"{self.base_url}/health")
            if response.status_code != 200:
                return "unreachable"
            payload = response.json()
            loaded = payload.get("loaded") or payload.get("data", {}).get("loaded")
            return "ready" if loaded else "cold"
        except Exception:  # noqa: BLE001 - health aggregation is best effort
            return "unreachable"

    async def poll(self, upstream_id: str) -> UpstreamResult:
        response = await self.client.post(
            f"{self.base_url}/query_result",
            json={"task_id_list": [upstream_id]},
        )
        if response.status_code >= 400:
            raise RuntimeError(_error_detail(response))
        wrapper = response.json()
        rows = wrapper.get("data") or []
        if wrapper.get("code") != 200 or not rows:
            return UpstreamResult.failed(
                str(wrapper.get("error") or "ACE-Step task is unavailable")
            )
        row = rows[0]
        status = int(row.get("status", 0))
        if status == 0:
            return UpstreamResult.running("ACE-Step generation")
        if status == 2:
            return UpstreamResult.failed(str(row.get("error") or "ACE-Step generation failed"))

        raw_result = row.get("result") or "[]"
        results = json.loads(raw_result) if isinstance(raw_result, str) else raw_result
        if not results or not results[0].get("file"):
            return UpstreamResult.failed("ACE-Step produced no audio file")
        file_url = str(results[0]["file"])
        download = await self.client.get(f"{self.base_url}{file_url}")
        if download.status_code >= 400:
            raise RuntimeError(_error_detail(download))
        parsed = urlparse(file_url)
        source_path = unquote(parse_qs(parsed.query).get("path", ["result.wav"])[0])
        filename = Path(source_path).name or "result.wav"
        media_type = download.headers.get("content-type", "audio/wav").split(";", 1)[0]
        return UpstreamResult.succeeded(download.content, filename, media_type)

    async def aclose(self) -> None:
        await self.client.aclose()


class MuScriptorClient:
    def __init__(self, base_url: str, *, client: httpx.AsyncClient | None = None):
        self.base_url = base_url.rstrip("/")
        self.client = client or httpx.AsyncClient(timeout=1200)

    async def transcribe(
        self,
        path: Path,
        instruments: list[str],
        detect_tempo: bool,
    ) -> bytes:
        fields: list[tuple[str, tuple[None, str] | tuple[str, bytes, str]]] = [
            ("audio_file", (path.name, path.read_bytes(), "application/octet-stream"))
        ]
        fields.extend(("instruments", (None, item)) for item in instruments)
        fields.extend(
            [
                ("detect_tempo", (None, "best-effort" if detect_tempo else "false")),
                ("return_file", (None, "false")),
            ]
        )
        response = await self.client.post(
            f"{self.base_url}/transcribe/midi",
            files=fields,
        )
        if response.status_code >= 400:
            raise RuntimeError(_error_detail(response))
        return response.content

    async def health(self) -> str:
        try:
            response = await self.client.get(f"{self.base_url}/health")
            if response.status_code != 200:
                return "unreachable"
            return "ready" if response.json().get("loaded") else "cold"
        except Exception:  # noqa: BLE001 - health aggregation is best effort
            return "unreachable"

    async def instruments(self) -> list[str]:
        try:
            response = await self.client.get(f"{self.base_url}/instruments")
            response.raise_for_status()
            grouped = response.json()
            return sorted({item for values in grouped.values() for item in values})
        except Exception:  # noqa: BLE001 - capabilities remain available when cold
            return []

    async def aclose(self) -> None:
        await self.client.aclose()
