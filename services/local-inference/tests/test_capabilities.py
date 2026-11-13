"""Routing contracts require no installed model libraries or model weights."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from local_inference.capabilities import (
    GENERATION_ENGINES, MUSIC_OPERATIONS, generation_engine, worker_environment,
)
from local_inference.engines import _ace_backend_state, run_manifest
from local_inference.main import worker_command


class CapabilityTests(unittest.TestCase):
    def test_every_declared_operation_routes_to_the_declared_environment(self):
        for engine in GENERATION_ENGINES:
            for operation in MUSIC_OPERATIONS:
                with self.subTest(preset=engine.id, operation=operation):
                    if operation in engine.operations:
                        self.assertEqual(worker_environment(operation, {'preset': engine.id}),
                                         engine.environment)
                    else:
                        with self.assertRaisesRegex(ValueError, 'Turbo or Quality'):
                            worker_environment(operation, {'preset': engine.id})

    def test_legacy_manifest_without_preset_still_routes_to_turbo(self):
        self.assertEqual(worker_environment('generation', {}), '.venv-ace')
        self.assertEqual(generation_engine('quality').inference_steps, 50)
        self.assertEqual(generation_engine('turbo').inference_steps, 8)

    def test_invalid_routes_fail_before_loading_or_decoding(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch('local_inference.engines._load_ace') as load, \
             patch('local_inference.engines._minimax') as minimax, \
             patch('local_inference.engines._decode_audio') as decode:
            for operation, preset in [('remix', 'minimax-cover'),
                                      ('generation', 'unknown'), ('unknown', 'turbo')]:
                manifest = {'operation': operation, 'parameters': {'preset': preset},
                            'output_dir': directory}
                with self.assertRaises(ValueError):
                    run_manifest(manifest)
                path = Path(directory) / 'manifest.json'
                path.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    worker_command(path)
            load.assert_not_called()
            minimax.assert_not_called()
            decode.assert_not_called()

    def test_backend_selection_is_observed_not_assumed_from_requested_mlx(self):
        dit = SimpleNamespace(device='mps', use_mlx_dit=False, mlx_decoder=None,
                              use_mlx_vae=True, mlx_vae=object())
        state = _ace_backend_state(dit, SimpleNamespace(device='mps', llm_backend='pt'))
        self.assertEqual(state, {'evidence': 'handler-configuration-not-execution',
                                'dit_eligible_backend': 'pytorch:mps',
                                'vae_eligible_backend': 'mlx',
                                'planner_configured_backend': 'pytorch:mps',
                                'executed_backends': 'unknown'})
        # Upstream may fall back without clearing eligibility flags.
        self.assertEqual(_ace_backend_state(dit, object())['planner_configured_backend'], 'unknown')
        self.assertEqual(_ace_backend_state(dit, SimpleNamespace(llm_backend='mlx'))['planner_configured_backend'], 'mlx')
        dit.use_mlx_dit = True
        self.assertEqual(_ace_backend_state(dit, None)['dit_eligible_backend'], 'unknown')
        dit.mlx_decoder = object()
        self.assertEqual(_ace_backend_state(dit, None)['dit_eligible_backend'], 'mlx')
        self.assertIsNone(_ace_backend_state(dit, None)['planner_configured_backend'])
        self.assertEqual(_ace_backend_state(object(), None)['vae_eligible_backend'], 'unknown')

    def test_nonmusic_routes_are_explicit(self):
        for operation in ('stem-split', 'vocal-swap', 'lyrics-transcription'):
            self.assertEqual(worker_environment(operation, {}), '.venv-mlx')
        self.assertEqual(worker_environment('transcription', {}), '.venv-muscriptor')
