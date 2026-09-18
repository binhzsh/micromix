"""One job per process; successful outputs are published as an atomic manifest."""
from __future__ import annotations

import json
import sys
from pathlib import Path

if __package__ in (None, ''):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from local_inference.engines import run_manifest
else:
    from .engines import run_manifest


def execute(manifest_path: Path) -> None:
    manifest = json.loads(manifest_path.read_text())
    directory = Path(manifest['output_dir']).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    result_path = directory / 'result.json'
    result_path.unlink(missing_ok=True)
    result = run_manifest(manifest)
    if not result.get('outputs'):
        raise RuntimeError('Worker produced no outputs')
    for output in result['outputs']:
        path = Path(output['path']).resolve()
        if not path.is_relative_to(directory) or not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError('Worker produced a missing, empty or out-of-directory output')
    pending = directory / 'result.json.tmp'
    pending.write_text(json.dumps(result))
    pending.replace(result_path)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit('usage: python -m local_inference.worker manifest.json')
    execute(Path(sys.argv[1]))


if __name__ == '__main__':
    main()
