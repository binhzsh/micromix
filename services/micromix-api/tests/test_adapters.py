from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest

from micromix_api.adapters import ACEClient, GPUClient, MuScriptorClient, RVCClient


@pytest.mark.asyncio
async def test_gpu_acquire_sends_wait_and_raises_on_backpressure():
    requests: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(json.loads(request.content))
        return httpx.Response(503, json={"detail": "GPU busy"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    gpu = GPUClient("http://gpu.test", client=client)

    with pytest.raises(RuntimeError, match="GPU busy"):
        await gpu.acquire("micromix-ace-step", 23_000, 60)

    assert requests == [
        {"app": "micromix-ace-step", "required_mib": 23_000, "wait_seconds": 60}
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
            "seeds": [7, 8],
            "variation_count": 2,
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
            "task_type": "text2music",
            "audio_duration": 30,
            "batch_size": 2,
            "use_random_seed": False,
            "seed": "7,8",
            "bpm": 92,
            "key_scale": "D Minor",
            "time_signature": "4",
        }
    ]
    await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize("operation", ["text", "reference"])
async def test_ace_submit_forwards_vocal_language_for_supported_operations(operation: str):
    captured: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(json.loads(request.content))
        return httpx.Response(200, json={"code": 200, "data": {"task_id": "task-1"}})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)
    await ace.submit({"prompt": "Vietnamese vocals", "operation": operation, "vocal_language": "vi"})
    assert captured[0]["vocal_language"] == "vi"
    await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize("operation", ["remix", "repaint"])
async def test_ace_submit_omits_vocal_language_for_source_transformations(operation: str):
    captured: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(json.loads(request.content))
        return httpx.Response(200, json={"code": 200, "data": {"task_id": "task-1"}})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)
    parameters = {"prompt": "transform", "operation": operation, "vocal_language": "vi"}
    if operation == "repaint":
        parameters.update(start_seconds=5, end_seconds=12)
    await ace.submit(parameters)
    assert "vocal_language" not in captured[0]
    await client.aclose()


@pytest.mark.asyncio
async def test_ace_poll_parses_result_and_downloads_audio():
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.path)
        if request.url.path == "/query_result":
            result = json.dumps(
                [
                    {"file": "/app/output/first.wav", "status": 1},
                    {"file": "/app/output/second.wav", "status": 1},
                ]
            )
            return httpx.Response(
                200,
                json={"code": 200, "data": [{"task_id": "task-1", "status": 1, "result": result}]},
            )
        if request.url.path == "/v1/audio":
            filename = Path(request.url.params["path"]).name
            return httpx.Response(
                200,
                content=f"RIFF-{filename}".encode(),
                headers={"content-type": "audio/wav; charset=binary"},
            )
        raise AssertionError(request.url)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)

    result = await ace.poll("task-1")

    assert result.state == "succeeded"
    assert [
        (output.data, output.filename, output.media_type)
        for output in result.outputs
    ] == [
        (b"RIFF-first.wav", "first.wav", "audio/wav"),
        (b"RIFF-second.wav", "second.wav", "audio/wav"),
    ]
    assert calls == ["/query_result", "/v1/audio", "/v1/audio"]
    await client.aclose()


@pytest.mark.asyncio
async def test_ace_poll_accepts_audio_route_in_file_field():
    audio_route = "/v1/audio?path=%2Fapp%2F.cache%2Facestep%2Ftmp%2Fapi_audio%2Fresult.wav"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/query_result":
            result = json.dumps([{"file": audio_route, "status": 1}])
            return httpx.Response(
                200,
                json={
                    "code": 200,
                    "data": [
                        {
                            "task_id": "task-1",
                            "status": 1,
                            "result": result,
                        }
                    ],
                },
            )
        assert str(request.url).endswith(audio_route)
        return httpx.Response(
            200,
            content=b"RIFF-result",
            headers={"content-type": "audio/wav"},
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)

    result = await ace.poll("task-1")

    assert result.state == "succeeded"
    assert result.outputs[0].filename == "result.wav"
    assert result.outputs[0].data == b"RIFF-result"
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


@pytest.mark.asyncio
async def test_rvc_client_forwards_private_conversion_contract():
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured.update(json.loads(request.content))
        return httpx.Response(200, json={"output_path": "/data/assets/job/rvc-output.wav"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    rvc = RVCClient("http://rvc.test", client=client)

    output = await rvc.convert(
        Path("/data/assets/input.wav"),
        Path("/voices/models/private.pth"),
        Path("/voices/indexes/private.index"),
        Path("/data/assets/job/rvc-output.wav"),
        -3,
        "rmvpe",
    )

    assert output == Path("/data/assets/job/rvc-output.wav")
    assert captured == {
        "source_path": "/data/assets/input.wav",
        "model_path": "/voices/models/private.pth",
        "index_path": "/voices/indexes/private.index",
        "output_path": "/data/assets/job/rvc-output.wav",
        "pitch_shift_semitones": -3,
        "f0_method": "rmvpe",
    }
    await client.aclose()
    await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("operation", "audio_argument", "audio_field", "extra_parameters", "expected"),
    [
        (
            "reference",
            "reference_audio",
            "reference_audio",
            {},
            {"task_type": "text2music", "thinking": "true"},
        ),
        (
            "remix",
            "source_audio",
            "src_audio",
            {"source_strength": 0.65},
            {
                "task_type": "cover",
                "thinking": "false",
                "audio_cover_strength": "0.65",
            },
        ),
        (
            "repaint",
            "source_audio",
            "src_audio",
            {
                "start_seconds": 12.5,
                "end_seconds": 24.0,
                "repaint_strength": 0.4,
            },
            {
                "task_type": "repaint",
                "thinking": "false",
                "repainting_start": "12.5",
                "repainting_end": "24.0",
                "repaint_mode": "balanced",
                "repaint_strength": "0.4",
            },
        ),
    ],
)
async def test_ace_submit_maps_audio_operations_to_multipart(
    tmp_path: Path,
    operation: str,
    audio_argument: str,
    audio_field: str,
    extra_parameters: dict,
    expected: dict[str, str],
):
    source = tmp_path / "source.wav"
    source.write_bytes(b"RIFF-source")

    def handler(request: httpx.Request) -> httpx.Response:
        body = request.content
        assert f'name="{audio_field}"; filename="source.wav"'.encode() in body
        assert b"RIFF-source" in body
        fields = {
            "batch_size": "2",
            "use_random_seed": "false",
            "seed": "11,12",
            **expected,
        }
        for name, value in fields.items():
            marker = f'name="{name}"'.encode()
            assert marker in body
            assert f"\r\n\r\n{value}\r\n".encode() in body
        return httpx.Response(
            200,
            json={"code": 200, "data": {"task_id": "task-audio"}},
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)

    task_id = await ace.submit(
        {
            "operation": operation,
            "prompt": "new arrangement",
            "preset": "quality",
            "variation_count": 2,
            "seeds": [11, 12],
            **extra_parameters,
        },
        **{audio_argument: source},
    )

    assert task_id == "task-audio"
    await client.aclose()


@pytest.mark.asyncio
async def test_ace_submit_rejects_reference_and_source_together(tmp_path: Path):
    source = tmp_path / "source.wav"
    source.write_bytes(b"RIFF-source")
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda _: None))
    ace = ACEClient("http://ace.test", client=client)

    with pytest.raises(ValueError, match="both"):
        await ace.submit(
            {
                "operation": "remix",
                "prompt": "song",
                "variation_count": 1,
                "seeds": [1],
            },
            reference_audio=source,
            source_audio=source,
        )

    await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("raw_result", "row_status", "expected_state"),
    [
        ("[]", 1, "missing"),
        (
            '[{"file": "/v1/audio?path=%2Ftmp%2Fpending.wav", "status": 0}]',
            1,
            "running",
        ),
    ],
)
async def test_ace_poll_distinguishes_missing_and_running_results(
    raw_result: str,
    row_status: int,
    expected_state: str,
):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "code": 200,
                "data": [
                    {
                        "task_id": "task-1",
                        "status": row_status,
                        "result": raw_result,
                    }
                ],
            },
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)

    result = await ace.poll("task-1")

    assert result.state == expected_state
    await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("legacy_seed", "expected_random", "expected_seed"),
    [
        (9, False, 9),
        (None, True, None),
    ],
)
async def test_ace_submit_accepts_pre_upgrade_seed_parameters(
    legacy_seed: int | None,
    expected_random: bool,
    expected_seed: int | None,
):
    captured: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(json.loads(request.content))
        return httpx.Response(
            200,
            json={"code": 200, "data": {"task_id": "legacy-task"}},
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    ace = ACEClient("http://ace.test", client=client)
    parameters = {
        "prompt": "legacy queued song",
        "preset": "turbo",
        "duration_seconds": 10,
    }
    if legacy_seed is not None:
        parameters["seed"] = legacy_seed

    task_id = await ace.submit(parameters)

    assert task_id == "legacy-task"
    assert captured[0]["batch_size"] == 1
    assert captured[0]["use_random_seed"] is expected_random
    if expected_seed is None:
        assert "seed" not in captured[0]
    else:
        assert captured[0]["seed"] == expected_seed
    await client.aclose()


@pytest.mark.asyncio
async def test_ace_poll_treats_worker_missing_status_as_missing():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "code": 200,
                "data": [{"task_id": "lost", "status": 3, "result": "[]"}],
            },
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    result = await ACEClient("http://ace.test", client=client).poll("lost")

    assert result.state == "missing"
    await client.aclose()
