from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class Settings:
    database_path: Path
    asset_root: Path
    upload_root: Path
    retention_days: int
    ace_url: str
    muscriptor_url: str
    gpu_router_url: str
    max_upload_mib: int = 200
    voice_profile_root: Path = Path("/voices")

    @classmethod
    def from_env(cls) -> "Settings":
        data_root = Path(os.getenv("DATA_ROOT", "/data"))
        return cls(
            database_path=Path(os.getenv("DATABASE_PATH", data_root / "gateway.db")),
            asset_root=Path(os.getenv("ASSET_ROOT", data_root / "assets")),
            upload_root=Path(os.getenv("UPLOAD_ROOT", data_root / "uploads")),
            retention_days=int(os.getenv("RETENTION_DAYS", "7")),
            ace_url=os.getenv("ACE_URL", "http://ace-step:8001"),
            muscriptor_url=os.getenv("MUSCRIPTOR_URL", "http://muscriptor:8901"),
            gpu_router_url=os.getenv("GPU_ROUTER_URL", "http://gpu-router:9999"),
            max_upload_mib=int(os.getenv("MAX_UPLOAD_MIB", "200")),
            voice_profile_root=Path(os.getenv("VOICE_PROFILE_ROOT", "/voices")),
        )
