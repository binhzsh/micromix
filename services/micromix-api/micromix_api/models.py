from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class JobKind(str, Enum):
    generation = "generation"
    transcription = "transcription"


class GenerationOperation(str, Enum):
    text = "text"
    reference = "reference"
    remix = "remix"
    repaint = "repaint"


class JobState(str, Enum):
    queued = "queued"
    acquiring_gpu = "acquiring_gpu"
    running = "running"
    succeeded = "succeeded"
    failed = "failed"
    cancelled = "cancelled"


class AssetDirection(str, Enum):
    input = "input"
    output = "output"


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


class JobAssetLink(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    position: int
    asset: AssetRecord


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
    inputs: list[JobAssetLink] = Field(default_factory=list)
    outputs: list[JobAssetLink] = Field(default_factory=list)
    asset: AssetRecord | None = None


class GenerationControls(BaseModel):
    model_config = ConfigDict(extra="forbid")

    prompt: str = Field(min_length=1, max_length=4000)
    lyrics: str | None = Field(default=None, max_length=50_000)
    preset: Literal["turbo", "quality"] = "turbo"
    seed: int | None = Field(default=None, ge=0, le=4_294_967_295)
    variation_count: int = Field(default=2, ge=1, le=4)

    @field_validator("prompt")
    @classmethod
    def prompt_must_have_content(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("prompt must not be blank")
        return value


class GenerationRequest(GenerationControls):
    variation_count: int = Field(default=1, ge=1, le=4)
    duration_seconds: float = Field(default=30, ge=10, le=600)
    bpm: int | None = Field(default=None, ge=30, le=300)
    key: str | None = Field(default=None, max_length=32)
    time_signature: Literal["2", "3", "4", "6"] | None = None


class ReferenceGenerationRequest(GenerationControls):
    reference_asset_id: str = Field(min_length=1)
    duration_seconds: float = Field(default=30, ge=10, le=600)
    bpm: int | None = Field(default=None, ge=30, le=300)
    key: str | None = Field(default=None, max_length=32)
    time_signature: Literal["2", "3", "4", "6"] | None = None


class RemixRequest(GenerationControls):
    source_asset_id: str = Field(min_length=1)
    source_strength: float = Field(default=0.6, ge=0.0, le=1.0)


class RepaintRequest(GenerationControls):
    source_asset_id: str = Field(min_length=1)
    start_seconds: float = Field(ge=0.0)
    end_seconds: float = Field(gt=0.0)
    repaint_strength: float = Field(default=0.5, ge=0.0, le=1.0)

    @model_validator(mode="after")
    def validate_interval(self) -> "RepaintRequest":
        duration = self.end_seconds - self.start_seconds
        if duration < 3.0:
            raise ValueError("repaint interval must be at least 3 seconds")
        if duration > 90.0:
            raise ValueError("repaint interval must not exceed 90 seconds")
        return self


class GenerationPreset(BaseModel):
    id: Literal["turbo", "quality"]
    label: str
    model: str
    inference_steps: int


class CapabilitiesResponse(BaseModel):
    generation_presets: list[GenerationPreset]
    transcription_instruments: list[str]
