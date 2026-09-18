"""Adapter regressions: replace only the heavy upstream dependency boundary."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from local_inference import engines


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.wav'
        self.source.write_bytes(b'source')

    def manifest(self, operation='generation', **parameters):
        return {'operation': operation, 'parameters': {'preset': 'turbo', 'seed': 42,
                'prompt': 'music', 'source_path': str(self.source), **parameters},
                'output_dir': str(self.root / 'out'), 'inputs': []}

    def test_ace_conditioning_controls_seeds_and_steps(self):
        calls = []
        def generate(dit, lm, params, config, save_dir):
            calls.append((params, config))
            path = Path(save_dir) / 'render.wav'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'audio')
            return SimpleNamespace(success=True, audios=[{'path': str(path)}])
        with patch.object(engines, '_load_ace', return_value=(object(), object(), SimpleNamespace, SimpleNamespace, generate)):
            for operation, task in [('generation', 'text2music'), ('reference-generation', 'text2music'), ('remix', 'cover'), ('repaint', 'repaint')]:
                result = engines.run_manifest(self.manifest(operation, preset='quality', variation_count=4,
                    bpm=98, key='C major', time_signature='6/8', vocal_language='en', start_seconds=3, end_seconds=7, source_strength=.65, repaint_strength=.8))
                self.assertEqual(len(result['outputs']), 4)
                self.assertEqual([x[0].seed for x in calls[-4:]], [42, 43, 44, 45])
                p, c = calls[-1]
                self.assertEqual((p.task_type, p.bpm, p.keyscale, p.timesignature, p.vocal_language, p.inference_steps),
                                 (task, 98, 'C major', '6', 'en', 50))
                self.assertEqual(p.audio_cover_strength, .65)
                self.assertEqual(p.repaint_strength, .8)
                self.assertFalse(c.use_random_seed)
                self.assertEqual(c.seeds, [45])
                if operation != 'generation':
                    self.assertEqual(p.lyrics, '')
                    self.assertFalse(p.instrumental)
                if operation == 'reference-generation':
                    self.assertEqual(p.reference_audio, str(self.source))
                elif operation in ('remix', 'repaint'):
                    self.assertEqual(p.src_audio, str(self.source))
                if operation == 'repaint':
                    self.assertEqual((p.repainting_start, p.repainting_end), (3, 7))

    def test_transcription_forwards_instruments_and_tempo(self):
        calls = []
        class Model:
            def transcribe_and_postprocess(self, **kwargs):
                calls.append(kwargs)
                return b'MThd-test', None
        with patch.object(engines, '_load_muscriptor', return_value=Model()), patch.object(engines, '_decode_audio', return_value=self.source):
            result = engines.run_manifest(self.manifest('transcription', instruments=['violin'], detect_tempo=True))
        self.assertEqual(calls[0]['instruments'], ['violin'])
        self.assertIs(calls[0]['detect_tempo'], True)
        self.assertEqual(Path(result['outputs'][0]['path']).read_bytes(), b'MThd-test')

    def test_rvc_loads_selected_model_and_index(self):
        model = self.root / 'private.safetensors'
        index = self.root / 'private.index'
        model.write_bytes(b'voice')
        index.write_bytes(b'index')
        calls = []
        class Pipeline:
            def convert(self, **kwargs):
                calls.append(kwargs)
                Path(kwargs['output_path']).write_bytes(b'converted')
        with patch.object(engines, '_load_rvc', return_value=Pipeline()) as loader:
            engines.run_manifest(self.manifest('vocal-swap', model_path=str(model), index_path=str(index), pitch_shift=3, index_rate=.7))
        loader.assert_called_once_with(str(model))
        self.assertEqual(calls[0]['index_path'], str(index))
        self.assertEqual(calls[0]['f0_shift'], 3)

    def test_stt_output_is_object_not_iterable(self):
        self.assertEqual(engines.stt_text(SimpleNamespace(text='  sung words  ')), 'sung words')

    def test_rejects_minimax_reimagine_instead_of_approximating(self):
        with self.assertRaisesRegex(ValueError, 'generation only'):
            engines.run_manifest(self.manifest('remix', preset='minimax-cover'))

    def test_worker_does_not_publish_missing_or_partial_outputs(self):
        from local_inference.worker import execute
        manifest = self.manifest()
        file = self.root / 'manifest.json'
        file.write_text(json.dumps(manifest))
        with patch('local_inference.worker.run_manifest', return_value={'outputs': [{'path': str(self.root / 'missing')}]}):
            with self.assertRaises(RuntimeError):
                execute(file)
        self.assertFalse((Path(manifest['output_dir']) / 'result.json').exists())

    def test_voice_revision_changes_fail_before_loading(self):
        model = self.root / 'private.safetensors'
        model.write_bytes(b'changed after submission')
        with patch.object(engines, '_load_rvc') as loader:
            with self.assertRaisesRegex(ValueError, 'changed since submission'):
                engines.run_manifest(self.manifest('vocal-swap', model_path=str(model), model_revision='sha256:' + '0' * 64))
        loader.assert_not_called()

    def test_seed_wraparound_and_persisted_seed_validation(self):
        self.assertEqual(engines.variation_seeds({'seed': 4294967295, 'variation_count': 2}), [4294967295, 0])
        with self.assertRaises(ValueError):
            engines.variation_seeds({'seed': 1, 'variation_count': 2, 'seeds': [1]})

    def test_sam_returns_both_target_and_residual_in_order(self):
        class Model:
            sample_rate = 48000
            def separate_long(self, *, audios, descriptions, chunk_seconds, overlap_seconds, ode_decode_chunk_size, seed):
                self_test.assertEqual(descriptions, ['drums'])
                return SimpleNamespace(target=[b'target'], residual=[b'residual'])
        self_test = self
        def processor(*, descriptions, audios):
            return SimpleNamespace(audios=audios, descriptions=descriptions)
        def save(audio, path, sample_rate):
            Path(path).write_bytes(audio)
        with patch.object(engines, '_load_sam', return_value=(Model(), processor, save)):
            result = engines.run_manifest(self.manifest('stem-split', description='drums'))
        self.assertEqual([x['name'] for x in result['outputs']], ['target', 'residual'])
        self.assertEqual([Path(x['path']).read_bytes() for x in result['outputs']], [b'target', b'residual'])

    def test_direct_worker_entrypoint_reaches_dispatch_without_pythonpath(self):
        import os
        import subprocess
        import sys
        from local_inference import worker
        manifest = self.manifest('unknown')
        file = self.root / 'manifest.json'
        file.write_text(json.dumps(manifest))
        environment = {k: v for k, v in os.environ.items() if k != 'PYTHONPATH'}
        result = subprocess.run([sys.executable, worker.__file__, str(file)], cwd=self.root,
                                env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unknown operation: unknown', result.stderr)
        self.assertNotIn('ImportError', result.stderr)
