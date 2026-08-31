from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from fastapi import HTTPException

import app as worker


class RVCWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.assets = root / "assets"
        self.voices = root / "voices"
        self.assets.mkdir()
        self.voices.mkdir()
        self.source = self.assets / "source.wav"
        self.model = self.voices / "private.pth"
        self.source.write_bytes(b"RIFF")
        self.model.write_bytes(b"model")
        self.original_asset_root = worker.ASSET_ROOT
        self.original_voice_root = worker.VOICE_ROOT
        worker.ASSET_ROOT = self.assets
        worker.VOICE_ROOT = self.voices

    def tearDown(self) -> None:
        worker.ASSET_ROOT = self.original_asset_root
        worker.VOICE_ROOT = self.original_voice_root
        self.temporary_directory.cleanup()

    def test_rejects_output_outside_private_asset_mount(self) -> None:
        request = worker.ConversionRequest(
            source_path=str(self.source),
            model_path=str(self.model),
            output_path="/tmp/converted.wav",
        )

        with self.assertRaisesRegex(HTTPException, "output path must remain"):
            worker.convert(request)

    def test_rejects_pitch_methods_other_than_rmvpe(self) -> None:
        request = worker.ConversionRequest(
            source_path=str(self.source),
            model_path=str(self.model),
            output_path=str(self.assets / "converted.wav"),
            f0_method="crepe",
        )

        with self.assertRaisesRegex(HTTPException, "unsupported vocal pitch method"):
            worker.convert(request)
