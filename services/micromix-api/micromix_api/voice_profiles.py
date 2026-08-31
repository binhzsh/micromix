from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class VoiceProfileError(ValueError):
    """A private voice profile is malformed, unavailable, or unsafe."""


@dataclass(frozen=True, slots=True)
class VoiceProfile:
    id: str
    display_name: str
    revision: str
    model_path: Path
    index_path: Path | None


class VoiceProfileRegistry:
    def __init__(self, root: Path):
        self.root = root.resolve()

    def resolve(self, profile_id: str) -> VoiceProfile:
        profiles = self._manifest().get("profiles", [])
        if not isinstance(profiles, list):
            raise VoiceProfileError("private voice profile manifest is invalid")
        profile = next(
            (value for value in profiles if isinstance(value, dict) and value.get("id") == profile_id),
            None,
        )
        if profile is None:
            raise VoiceProfileError("private voice profile is unavailable")
        return VoiceProfile(
            id=self._required(profile, "id"),
            display_name=self._required(profile, "display_name"),
            revision=self._required(profile, "revision"),
            model_path=self._contained_file(self._required(profile, "model")),
            index_path=self._contained_file(profile["index"]) if profile.get("index") else None,
        )

    def _manifest(self) -> dict[str, Any]:
        try:
            value = json.loads((self.root / "profiles.json").read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise VoiceProfileError("private voice profile manifest is unavailable") from exc
        if not isinstance(value, dict):
            raise VoiceProfileError("private voice profile manifest is invalid")
        return value

    def _contained_file(self, relative_path: str) -> Path:
        if not isinstance(relative_path, str) or not relative_path:
            raise VoiceProfileError("private voice profile path is invalid")
        path = (self.root / relative_path).resolve()
        if not path.is_relative_to(self.root):
            raise VoiceProfileError("private voice profile path escapes private model root")
        if not path.is_file():
            raise VoiceProfileError("private voice profile model is unavailable")
        return path

    @staticmethod
    def _required(value: dict[str, Any], key: str) -> str:
        result = value.get(key)
        if not isinstance(result, str) or not result.strip():
            raise VoiceProfileError(f"private voice profile {key} is invalid")
        return result
