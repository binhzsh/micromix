from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from micromix_api.config import Settings
from micromix_api.main import create_app
from micromix_api.models import JobState


@pytest.fixture
async def client(tmp_path: Path):
    settings = Settings(
        database_path=tmp_path / "gateway.db",
        asset_root=tmp_path / "assets",
        upload_root=tmp_path / "uploads",
        retention_days=7,
        ace_url="http://ace.test",
        muscriptor_url="http://muscriptor.test",
        gpu_router_url="http://gpu.test",
        max_upload_mib=1,
    )
    app = create_app(settings=settings, start_dispatcher=False)
    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as value:
            yield value


@pytest.mark.asyncio
async def test_health_and_capabilities_have_stable_shapes(client: httpx.AsyncClient):
    health = (await client.get("/v1/health")).json()
    capabilities = (await client.get("/v1/capabilities")).json()

    assert health["service"] == "micromix-api"
    assert set(health["workers"]) == {"ace_step", "muscriptor"}
    assert [item["id"] for item in capabilities["generation_presets"]] == [
        "turbo",
        "quality",
    ]
    assert "transcription_instruments" in capabilities


@pytest.mark.asyncio
async def test_generation_submission_and_lookup(client: httpx.AsyncClient):
    response = await client.post(
        "/v1/jobs/generation",
        json={
            "prompt": "warm analog jazz",
            "lyrics": "[Verse]\nHello",
            "preset": "turbo",
            "duration_seconds": 30,
            "seed": 42,
        },
    )

    assert response.status_code == 202
    created = response.json()
    assert created["kind"] == "generation"
    assert created["state"] == "queued"
    fetched = (await client.get(f"/v1/jobs/{created['id']}")).json()
    assert fetched["parameters"]["prompt"] == "warm analog jazz"
    assert fetched["parameters"]["preset"] == "turbo"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "payload",
    [
        {"prompt": "", "preset": "turbo", "duration_seconds": 30},
        {"prompt": "song", "preset": "unknown", "duration_seconds": 30},
        {"prompt": "song", "preset": "turbo", "duration_seconds": 9},
        {"prompt": "song", "preset": "turbo", "duration_seconds": 601},
        {"prompt": "song", "preset": "turbo", "duration_seconds": 30, "bpm": 301},
    ],
)
async def test_generation_validation_rejects_invalid_input(client: httpx.AsyncClient, payload: dict):
    response = await client.post("/v1/jobs/generation", json=payload)
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_cancel_queued_job_is_terminal_and_retained(client: httpx.AsyncClient):
    created = (
        await client.post(
            "/v1/jobs/generation",
            json={"prompt": "cancel me", "preset": "quality", "duration_seconds": 10},
        )
    ).json()

    response = await client.post(f"/v1/jobs/{created['id']}/cancel")

    assert response.status_code == 200
    assert response.json()["state"] == JobState.cancelled.value
    assert (await client.get(f"/v1/jobs/{created['id']}")).status_code == 200


@pytest.mark.asyncio
async def test_transcription_submission_persists_upload_without_exposing_path(
    client: httpx.AsyncClient,
):
    response = await client.post(
        "/v1/jobs/transcription",
        files=[
            ("audio_file", ("voice.wav", b"RIFF-input", "audio/wav")),
            ("instruments", (None, "vocals")),
            ("instruments", (None, "piano")),
            ("detect_tempo", (None, "true")),
        ],
    )

    assert response.status_code == 202
    job = response.json()
    assert job["kind"] == "transcription"
    assert job["parameters"] == {
        "filename": "voice.wav",
        "instruments": ["vocals", "piano"],
        "detect_tempo": True,
    }
    assert "input_path" not in response.text


@pytest.mark.asyncio
async def test_audio_asset_upload_is_downloadable_and_hides_server_path(
    client: httpx.AsyncClient,
):
    response = await client.post(
        "/v1/assets",
        files={"audio_file": ("../source.wav", b"RIFF-input", "audio/wav")},
    )

    assert response.status_code == 201
    asset = response.json()
    assert asset["filename"] == "source.wav"
    assert asset["media_type"] == "audio/wav"
    assert "relative_path" not in asset
    downloaded = await client.get(asset["download_url"])
    assert downloaded.content == b"RIFF-input"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("data", "expected_status"),
    [
        (b"", 400),
        (b"x" * ((1024 * 1024) + 1), 413),
    ],
)
async def test_audio_asset_upload_rejects_empty_and_oversized_files(
    client: httpx.AsyncClient,
    data: bytes,
    expected_status: int,
):
    response = await client.post(
        "/v1/assets",
        files={"audio_file": ("source.wav", data, "audio/wav")},
    )

    assert response.status_code == expected_status


@pytest.mark.asyncio
async def test_unknown_job_and_asset_return_404(client: httpx.AsyncClient):
    assert (await client.get("/v1/jobs/missing")).status_code == 404
    assert (await client.get("/v1/assets/missing")).status_code == 404
