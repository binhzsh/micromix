from __future__ import annotations

import json
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

import httpx

from .coordinator import UpstreamOutput, UpstreamResult


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

    async def submit(
        self,
        parameters: dict,
        *,
        reference_audio: Path | None = None,
        source_audio: Path | None = None,
    ) -> str:
        if reference_audio is not None and source_audio is not None:
            raise ValueError("cannot submit both reference and source audio")
        preset = parameters.get("preset", "turbo")
        model, steps = self.MODELS[preset]
        operation = parameters.get("operation", "text")
        task_type = {
            "text": "text2music",
            "reference": "text2music",
            "remix": "cover",
            "repaint": "repaint",
        }[operation]
        payload: dict = {
            "prompt": parameters["prompt"],
            "lyrics": parameters.get("lyrics", ""),
            "model": model,
            "inference_steps": steps,
            "thinking": operation in {"text", "reference"},
            "lm_model_path": "acestep-5Hz-lm-4B",
            "audio_format": "wav",
            "task_type": task_type,
            "batch_size": parameters.get("variation_count", 1),
        }
        if operation in {"text", "reference"} and parameters.get("vocal_language") is not None:
            payload["vocal_language"] = parameters["vocal_language"]
        seeds = parameters.get("seeds")
        if seeds:
            payload["use_random_seed"] = False
            payload["seed"] = ",".join(str(seed) for seed in seeds)
        elif parameters.get("seed") is not None:
            payload["use_random_seed"] = False
            payload["seed"] = parameters["seed"]
        else:
            payload["use_random_seed"] = True
        if parameters.get("duration_seconds") is not None:
            payload["audio_duration"] = parameters["duration_seconds"]
        for source, target in (
            ("bpm", "bpm"),
            ("key", "key_scale"),
            ("time_signature", "time_signature"),
        ):
            if parameters.get(source) is not None:
                payload[target] = parameters[source]
        if operation == "remix":
            payload["audio_cover_strength"] = parameters.get(
                "source_strength",
                0.6,
            )
        elif operation == "repaint":
            payload.update(
                repainting_start=parameters["start_seconds"],
                repainting_end=parameters["end_seconds"],
                repaint_mode="balanced",
                repaint_strength=parameters.get("repaint_strength", 0.5),
            )

        audio_path = reference_audio or source_audio
        if audio_path is None:
            response = await self.client.post(
                f"{self.base_url}/release_task",
                json=payload,
            )
        else:
            field_name = "reference_audio" if reference_audio else "src_audio"
            form = {
                key: (
                    str(value).lower()
                    if isinstance(value, bool)
                    else str(value)
                )
                for key, value in payload.items()
            }
            with audio_path.open("rb") as audio_stream:
                response = await self.client.post(
                    f"{self.base_url}/release_task",
                    data=form,
                    files={
                        field_name: (
                            audio_path.name,
                            audio_stream,
                            "application/octet-stream",
                        )
                    },
                )
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
        if wrapper.get("code") != 200:
            return UpstreamResult.failed(
                str(wrapper.get("error") or "ACE-Step task is unavailable")
            )
        if not rows:
            return UpstreamResult.missing()
        row = rows[0]
        status = int(row.get("status", 0))
        if status == 0:
            return UpstreamResult.running("ACE-Step generation")
        if status == 2:
            return UpstreamResult.failed(str(row.get("error") or "ACE-Step generation failed"))

        raw_result = row.get("result") or "[]"
        results = json.loads(raw_result) if isinstance(raw_result, str) else raw_result
        if not results:
            return UpstreamResult.missing()
        if any(int(result.get("status", 0)) == 0 for result in results):
            return UpstreamResult.running("ACE-Step generation")
        if any(not result.get("file") for result in results):
            return UpstreamResult.failed("ACE-Step produced no audio file")
        outputs: list[UpstreamOutput] = []
        for result in results:
            source_path = str(result["file"])
            if result.get("url"):
                file_url = str(result["url"])
            elif source_path.startswith("/v1/audio?"):
                file_url = source_path
            else:
                file_url = f"/v1/audio?{urlencode({'path': source_path})}"
            filename_path = source_path
            if source_path.startswith("/v1/audio?"):
                query_path = parse_qs(urlsplit(source_path).query).get("path")
                if query_path:
                    filename_path = query_path[0]
            download = await self.client.get(f"{self.base_url}{file_url}")
            if download.status_code >= 400:
                raise RuntimeError(_error_detail(download))
            outputs.append(
                UpstreamOutput(
                    data=download.content,
                    filename=Path(filename_path).name or "result.wav",
                    media_type=download.headers.get(
                        "content-type",
                        "audio/wav",
                    ).split(";", 1)[0],
                )
            )
        return UpstreamResult.succeeded(tuple(outputs))

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
