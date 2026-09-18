"""Regression coverage for the local-model setup script."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class SetupScriptTests(unittest.TestCase):
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
