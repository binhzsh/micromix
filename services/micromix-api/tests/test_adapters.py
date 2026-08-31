from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from micromix_api.adapters import ACEClient, GPUClient, MuScriptorClient


@pytest.mark.asyncio
async def test_gpu_acquire_sends_wait_and_raises_on_backpressure():
    requests: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(json.loads(request.content))
        return httpx.Response(503, json={"detail": "GPU busy"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    gpu = GPUClient("http://gpu.test", client=client)

    with pytest.raises(RuntimeError, match="GPU busy"):
        await gpu.acquire("micromix-ace-step", 23_800, 60)

    assert requests == [
        {"app": "micromix-ace-step", "required_mib": 23_800, "wait_seconds": 60}
    ]
    await client.aclose()


@pytest.mark.asyncio
async def test_gpu_release_notifies_router():
    requests: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(json.loads(request.content))
        return httpx.Response(200, json={"released": True})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    gpu = GPUClient("http://gpu.test", client=client)

    await gpu.release("micromix-ace-step")

    assert requests == [{"app": "micromix-ace-step"}]
    await client.aclose()


@pytest.mark.asyncio
async def test_ace_submit_maps_turbo_profile_to_official_api():
    captured: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(json.loads(request.content))
        return httpx.Response(200, json={"code": 200, "data": {"task_id": "task-1"}})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)

    task_id = await ace.submit(
        {
            "prompt": "analog jazz",
            "lyrics": "hello",
            "preset": "turbo",
            "duration_seconds": 30,
            "seed": 7,
            "bpm": 92,
            "key": "D Minor",
            "time_signature": "4",
        }
    )

    assert task_id == "task-1"
    assert captured == [
        {
            "prompt": "analog jazz",
            "lyrics": "hello",
            "model": "acestep-v15-xl-turbo",
            "inference_steps": 8,
            "thinking": True,
            "lm_model_path": "acestep-5Hz-lm-4B",
            "audio_format": "wav",
            "audio_duration": 30,
            "use_random_seed": False,
            "seed": 7,
            "bpm": 92,
            "key_scale": "D Minor",
            "time_signature": "4",
        }
    ]
    await client.aclose()


@pytest.mark.asyncio
async def test_ace_poll_parses_result_and_downloads_audio():
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/query_result":
            result = json.dumps(
                [{"file": "/v1/audio?path=%2Ftmp%2Fresult.wav", "status": 1}]
            )
            return httpx.Response(
                200,
                json={"code": 200, "data": [{"task_id": "task-1", "status": 1, "result": result}]},
            )
        if request.url.path == "/v1/audio":
            return httpx.Response(200, content=b"RIFF-audio", headers={"content-type": "audio/wav"})
        raise AssertionError(request.url)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)

    result = await ace.poll("task-1")

    assert result.state == "succeeded"
    assert result.data == b"RIFF-audio"
    assert result.filename == "result.wav"
    assert calls == ["/query_result", "/v1/audio"]
    await client.aclose()


@pytest.mark.asyncio
async def test_muscriptor_posts_expected_multipart_fields(tmp_path: Path):
    source = tmp_path / "voice.wav"
    source.write_bytes(b"RIFF-input")

    def handler(request: httpx.Request) -> httpx.Response:
        body = request.content
        assert b'name="audio_file"; filename="voice.wav"' in body
        assert body.count(b'name="instruments"') == 2
        assert b"vocals" in body
        assert b"piano" in body
        assert b"best-effort" in body
        return httpx.Response(200, content=b"MThd-midi")

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    muscriptor = MuScriptorClient("http://muscriptor.test", client=client)

    output = await muscriptor.transcribe(source, ["vocals", "piano"], True)

    assert output == b"MThd-midi"
    await client.aclose()


@pytest.mark.asyncio
async def test_runtime_status_and_instrument_queries():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "gpu.test":
            return httpx.Response(
                200,
                json={"gpu": {"free_mib": 12_345}, "holders": []},
            )
        if request.url.host == "ace.test":
            return httpx.Response(200, json={"status": "ok", "loaded": True})
        if request.url.path == "/health":
            return httpx.Response(200, json={"status": "ok", "loaded": False})
        if request.url.path == "/instruments":
            return httpx.Response(200, json={"instruments": ["vocals", "piano"]})
        raise AssertionError(request.url)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    gpu = GPUClient("http://gpu.test", client=client)
    ace = ACEClient("http://ace.test", client=client)
    muscriptor = MuScriptorClient("http://muscriptor.test", client=client)

    assert (await gpu.status())["free_mib"] == 12_345
    assert await ace.health() == "ready"
    assert await muscriptor.health() == "cold"
    assert await muscriptor.instruments() == ["piano", "vocals"]
    await client.aclose()
