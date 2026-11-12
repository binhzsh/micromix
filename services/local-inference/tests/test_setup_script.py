"""Regression coverage for the local-model setup script."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class SetupScriptTests(unittest.TestCase):
    def test_installer_pins_match_adapter_provenance_and_compute_runtime(self):
        from local_inference.engines import (
            ACE_REVISION, MLX_AUDIO_REVISION, MUSCRIPTOR_REVISION, RVC_REVISION,
        )

        repository = Path(__file__).resolve().parents[3]
        script = (repository / 'scripts/setup-local-models.sh').read_text()
        for revision in (ACE_REVISION, MLX_AUDIO_REVISION, MUSCRIPTOR_REVISION, RVC_REVISION):
            self.assertIn(f'.git@{revision}', script)
        self.assertEqual(script.count("'mlx==0.32.4' 'mlx-metal==0.32.4'"), 2)
        self.assertIn('https://github.com/Neywa-Labs/mlx-audio.git', script)

    def test_install_without_dry_run_does_not_expand_an_unset_argument(self):
        repository = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as temporary:
            bin_dir = Path(temporary) / "bin"
            bin_dir.mkdir()
            for name, contents in {
                "uname": "#!/bin/sh\nif [ \"$1\" = -s ]; then echo Darwin; else echo arm64; fi\n",
                "ffmpeg": "#!/bin/sh\nexit 0\n",
                "uv": "#!/bin/sh\nif [ \"$1\" = venv ]; then mkdir -p \"$4/bin\"; touch \"$4/bin/python\"; fi\nexit 0\n",
            }.items():
                command = bin_dir / name
                command.write_text(contents)
                command.chmod(0o755)
            result = subprocess.run(
                ["bash", "scripts/setup-local-models.sh", "--engine", "ace"],
                cwd=repository,
                env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
