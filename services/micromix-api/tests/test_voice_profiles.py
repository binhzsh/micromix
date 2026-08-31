from __future__ import annotations

import json
from pathlib import Path

import pytest

from micromix_api.voice_profiles import VoiceProfileError, VoiceProfileRegistry


def write_manifest(root: Path, profiles: list[dict]) -> None:
    (root / "profiles.json").write_text(json.dumps({"profiles": profiles}))


def test_registry_resolves_private_profile_with_immutable_revision(tmp_path: Path):
    models = tmp_path / "models"
    models.mkdir()
    (models / "voice.pth").write_bytes(b"weights")
    (models / "voice.index").write_bytes(b"index")
    write_manifest(
        tmp_path,
        [
            {
                "id": "private-voice",
                "display_name": "Private Voice",
                "revision": "r1",
                "model": "models/voice.pth",
                "index": "models/voice.index",
            }
        ],
    )

    profile = VoiceProfileRegistry(tmp_path).resolve("private-voice")

    assert profile.id == "private-voice"
    assert profile.revision == "r1"
    assert profile.model_path == models / "voice.pth"
    assert profile.index_path == models / "voice.index"


def test_registry_refuses_paths_outside_private_model_root(tmp_path: Path):
    write_manifest(
        tmp_path,
        [{"id": "private-voice", "display_name": "Private Voice", "revision": "r1", "model": "../outside.pth"}],
    )

    with pytest.raises(VoiceProfileError, match="escapes"):
        VoiceProfileRegistry(tmp_path).resolve("private-voice")


def test_registry_refuses_missing_or_unknown_profiles(tmp_path: Path):
    write_manifest(tmp_path, [])

    with pytest.raises(VoiceProfileError, match="unavailable"):
        VoiceProfileRegistry(tmp_path).resolve("private-voice")
