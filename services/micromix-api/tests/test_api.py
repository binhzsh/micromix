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
    assert created["inputs"] == []
    assert created["outputs"] == []
    assert created["asset"] is None
    fetched = (await client.get(f"/v1/jobs/{created['id']}")).json()
    assert fetched["parameters"]["prompt"] == "warm analog jazz"
    assert fetched["parameters"]["preset"] == "turbo"


@pytest.mark.asyncio
@pytest.mark.parametrize("language", ["en", "vi"])
async def test_generation_submission_persists_supported_vocal_language(
    client: httpx.AsyncClient, language: str
):
    response = await client.post(
        "/v1/jobs/generation",
        json={"prompt": "bilingual vocal", "vocal_language": language},
    )

    assert response.status_code == 202
    job = (await client.get(f"/v1/jobs/{response.json()['id']}")).json()
    assert job["parameters"]["vocal_language"] == language


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "payload",
    [
        {"prompt": "", "preset": "turbo", "duration_seconds": 30},
        {"prompt": "song", "preset": "unknown", "duration_seconds": 30},
        {"prompt": "song", "preset": "turbo", "duration_seconds": 9},
        {"prompt": "song", "preset": "turbo", "duration_seconds": 601},
        {"prompt": "song", "preset": "turbo", "duration_seconds": 30, "bpm": 301},
        {"prompt": "song", "vocal_language": "fr"},
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


async def upload_test_asset(
    client: httpx.AsyncClient,
    *,
    media_type: str = "audio/wav",
) -> dict:
    response = await client.post(
        "/v1/assets",
        files={"audio_file": ("source.wav", b"RIFF-source", media_type)},
    )
    assert response.status_code == 201
    return response.json()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("route", "payload", "operation", "input_name"),
    [
        (
            "/v1/jobs/reference-generation",
            {"prompt": "dream pop"},
            "reference",
            "reference",
        ),
        (
            "/v1/jobs/remix",
            {"prompt": "heavy rock", "source_strength": 0.7},
            "remix",
            "source",
        ),
        (
            "/v1/jobs/repaint",
            {
                "prompt": "new bridge",
                "start_seconds": 12,
                "end_seconds": 20,
                "repaint_strength": 0.4,
            },
            "repaint",
            "source",
        ),
    ],
)
async def test_reimagine_submission_persists_operation_and_input(
    client: httpx.AsyncClient,
    route: str,
    payload: dict,
    operation: str,
    input_name: str,
):
    asset = await upload_test_asset(client)
    asset_key = (
        "reference_asset_id"
        if operation == "reference"
        else "source_asset_id"
    )

    response = await client.post(
        route,
        json={
            **payload,
            asset_key: asset["id"],
            "seed": 4_294_967_295,
            "variation_count": 2,
        },
    )

    assert response.status_code == 202
    job = response.json()
    assert job["parameters"]["operation"] == operation
    assert job["parameters"]["variation_count"] == 2
    assert job["parameters"]["seeds"] == [4_294_967_295, 0]
    assert asset_key not in job["parameters"]
    assert [(link["name"], link["asset"]["id"]) for link in job["inputs"]] == [
        (input_name, asset["id"])
    ]
    assert "upstream_recovery_count" not in response.text


@pytest.mark.asyncio
async def test_generation_submission_records_text_operation_and_seed_defaults(
    client: httpx.AsyncClient,
):
    response = await client.post(
        "/v1/jobs/generation",
        json={"prompt": "minimal techno"},
    )

    assert response.status_code == 202
    parameters = response.json()["parameters"]
    assert parameters["operation"] == "text"
    assert parameters["variation_count"] == 1
    assert len(parameters["seeds"]) == 1
    assert 0 <= parameters["seeds"][0] <= 4_294_967_295


@pytest.mark.asyncio
async def test_reimagine_submission_rejects_missing_and_non_audio_assets(
    client: httpx.AsyncClient,
):
    before = (await client.get("/v1/jobs")).json()
    missing = await client.post(
        "/v1/jobs/remix",
        json={"source_asset_id": "missing", "prompt": "rock"},
    )
    document = await upload_test_asset(client, media_type="text/plain")
    wrong_type = await client.post(
        "/v1/jobs/reference-generation",
        json={
            "reference_asset_id": document["id"],
            "prompt": "dream pop",
        },
    )

    assert missing.status_code == 404
    assert wrong_type.status_code == 422
    assert (await client.get("/v1/jobs")).json() == before


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("route", "payload"),
    [
        (
            "/v1/jobs/reference-generation",
            {"reference_asset_id": "unused", "prompt": "song", "variation_count": 5},
        ),
        (
            "/v1/jobs/remix",
            {"source_asset_id": "unused", "prompt": "song", "source_strength": 1.1},
        ),
        (
            "/v1/jobs/repaint",
            {
                "source_asset_id": "unused",
                "prompt": "song",
                "start_seconds": 1,
                "end_seconds": 2,
            },
        ),
    ],
)
async def test_reimagine_validation_does_not_create_jobs(
    client: httpx.AsyncClient,
    route: str,
    payload: dict,
):
    before = (await client.get("/v1/jobs")).json()

    response = await client.post(route, json=payload)

    assert response.status_code == 422
    assert (await client.get("/v1/jobs")).json() == before
