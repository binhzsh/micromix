from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class JobKind(str, Enum):
    generation = "generation"
    transcription = "transcription"


class JobState(str, Enum):
    queued = "queued"
    acquiring_gpu = "acquiring_gpu"
    running = "running"
    succeeded = "succeeded"
    failed = "failed"
    cancelled = "cancelled"


TERMINAL_STATES = {JobState.succeeded, JobState.failed, JobState.cancelled}


class AssetRecord(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    filename: str
    media_type: str
    size_bytes: int
    sha256: str
    download_url: str
    relative_path: str = Field(exclude=True)


class JobRecord(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    kind: JobKind
    state: JobState
    parameters: dict[str, Any]
    internal_parameters: dict[str, Any] = Field(default_factory=dict, exclude=True)
    progress: float | None = None
    progress_detail: str | None = None
    upstream_id: str | None = None
    cancel_requested: bool = False
    error: str | None = None
    created_at: datetime
    updated_at: datetime
    asset: AssetRecord | None = None


class GenerationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    prompt: str = Field(min_length=1, max_length=4000)
    lyrics: str | None = Field(default=None, max_length=50_000)
    preset: Literal["turbo", "quality"] = "turbo"
    duration_seconds: float = Field(default=30, ge=10, le=600)
    seed: int | None = None
    bpm: int | None = Field(default=None, ge=30, le=300)
    key: str | None = Field(default=None, max_length=32)
    time_signature: Literal["2", "3", "4", "6"] | None = None

    @field_validator("prompt")
    @classmethod
    def prompt_must_have_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("prompt must not be blank")
        return value


class GenerationPreset(BaseModel):
    id: Literal["turbo", "quality"]
    label: str
    model: str
    inference_steps: int


class CapabilitiesResponse(BaseModel):
    generation_presets: list[GenerationPreset]
    transcription_instruments: list[str]
