"""Local API capabilities remain an executable contract, not a model claim."""
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from fastapi.testclient import TestClient
from local_inference.main import create_app


class LocalContractTests(unittest.TestCase):
    def setUp(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.client = self.enterContext(TestClient(create_app(root, start_worker=False)))

    def test_every_advertised_preset_accepts_basic_generation(self):
        presets = self.client.get('/v1/capabilities').json()['generation_presets']
        self.assertEqual({p['id'] for p in presets}, {'turbo', 'quality', 'minimax-cover'})
        for preset in presets:
            with self.subTest(preset=preset['id']):
                response = self.client.post('/v1/jobs/generation', json={
                    'prompt': 'warm piano', 'preset': preset['id'],
                })
                self.assertEqual(response.status_code, 202, response.text)
                self.assertEqual(response.json()['parameters']['preset'], preset['id'])

    def test_catalog_operations_match_api_acceptance(self):
        source = self.client.post('/v1/assets', files={
            'audio_file': ('source.wav', b'fixture', 'audio/wav'),
        }).json()['id']
        for preset in self.client.get('/v1/capabilities').json()['generation_presets']:
            self.assertEqual(preset['musical_metadata'], preset['id'] != 'minimax-cover')
            self.assertEqual(preset['health_model'],
                             'minimax_music3' if preset['id'] == 'minimax-cover' else 'ace_step')
            for operation in ('reference-generation', 'remix', 'repaint'):
                body = {'prompt': 'jazz', 'preset': preset['id']}
                body['reference_asset_id' if operation == 'reference-generation' else 'source_asset_id'] = source
                if operation == 'repaint':
                    body.update(start_seconds=1, end_seconds=5)
                response = self.client.post('/v1/jobs/' + operation, json=body)
                self.assertEqual(response.status_code,
                                 202 if operation in preset['operations'] else 422, response.text)

    def test_generation_duration_limits_are_preset_specific(self):
        for preset, duration, expected in [
            ('minimax-cover', 360, 202),
            ('minimax-cover', 360.01, 422),
            ('minimax-cover', 600, 422),
            ('turbo', 600, 202),
            ('quality', 600, 202),
        ]:
            with self.subTest(preset=preset, duration=duration):
                response = self.client.post('/v1/jobs/generation', json={
                    'prompt': 'piano', 'preset': preset, 'duration_seconds': duration,
                })
                self.assertEqual(response.status_code, expected, response.text)
        self.assertEqual(len(self.client.get('/v1/jobs').json()), 3)

    def test_minimax_rejects_controls_it_cannot_apply(self):
        for field, value in [('bpm', 120), ('key', 'C minor'),
                             ('time_signature', '4'), ('vocal_language', 'vi'),
                             ('variation_count', 2)]:
            with self.subTest(field=field):
                response = self.client.post('/v1/jobs/generation', json={
                    'prompt': 'piano', 'preset': 'minimax-cover', field: value,
                })
                self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual(self.client.get('/v1/jobs').json(), [])

    def test_source_conditioning_does_not_fall_back_to_minimax(self):
        response = self.client.post('/v1/jobs/remix', json={
            'prompt': 'piano', 'preset': 'minimax-cover', 'source_asset_id': 'source',
        })
        self.assertEqual(response.status_code, 422)
        self.assertIn('Turbo or Quality', response.json()['detail'])

    def test_muscriptor_weight_marker_uses_configured_checkpoint(self):
        from local_inference import engines
        model_root = Path('/private/test-models')
        with patch.object(engines, 'MODELS_DIR', model_root):
            for configured, expected in [
                ('small', model_root / 'muscriptor-small/model.safetensors'),
                ('medium', model_root / 'muscriptor-medium/model.safetensors'),
                ('large', model_root / 'muscriptor-large/model.safetensors'),
                ('/private/custom/model.safetensors', Path('/private/custom/model.safetensors')),
            ]:
                with self.subTest(configured=configured), patch.dict(
                    os.environ, {'MICROMIX_MUSCRIPTOR_MODEL': configured}
                ):
                    self.assertEqual(engines.required_weight_paths()['muscriptor'], [expected])
            with patch.dict(os.environ, {}, clear=True):
                self.assertEqual(engines.required_weight_paths()['muscriptor'],
                                 [model_root / 'muscriptor-medium/model.safetensors'])

    def test_health_reports_selected_muscriptor_marker(self):
        from local_inference import engines
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        checkpoint = root / 'custom.safetensors'
        checkpoint.touch()
        with patch.object(engines, 'MODELS_DIR', root), patch.dict(
            os.environ, {'MICROMIX_MUSCRIPTOR_MODEL': str(checkpoint)}
        ), patch('local_inference.main.subprocess.run') as run:
            run.return_value.returncode = 0
            with patch('local_inference.main.SERVICE_ROOT', root):
                executable = root / '.venv-muscriptor/bin/python'
                executable.parent.mkdir(parents=True)
                executable.touch()
                self.assertEqual(self.client.get('/v1/health').json()['models']['muscriptor'], 'ready')
                checkpoint.unlink()
                health = self.client.get('/v1/health').json()
                self.assertEqual(health['models']['muscriptor'], 'weights_missing')
                self.assertEqual(health['missing_weights']['muscriptor'], [str(checkpoint)])

    def test_health_checks_configured_whisper_snapshot(self):
        from local_inference import engines
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        model = root / 'custom-whisper'
        model.mkdir()
        (model / 'config.json').touch()
        with patch.dict(os.environ, {'MICROMIX_WHISPER_MODEL': str(model)}), \
             patch('local_inference.main.subprocess.run') as run, \
             patch('local_inference.main.SERVICE_ROOT', root):
            executable = root / '.venv-mlx/bin/python'
            executable.parent.mkdir(parents=True)
            executable.touch()
            run.return_value.returncode = 0
            health = self.client.get('/v1/health').json()
            self.assertEqual(health['models']['whisper'], 'weights_missing')
            self.assertEqual(health['missing_weights']['whisper'], [str(model / 'model.safetensors')])
            (model / 'model.safetensors').touch()
            self.assertEqual(self.client.get('/v1/health').json()['models']['whisper'], 'ready')
            self.assertEqual(engines.required_weight_paths()['whisper'][0], model / 'config.json')

    def test_health_is_local_without_loading_any_model(self):
        health = self.client.get('/v1/health').json()
        self.assertEqual(health['service'], 'micromix-local-inference')
        self.assertEqual(health['status'], 'ready')
        self.assertIn('ace_step', health['models'])
        self.assertIn('muscriptor', health['models'])
        # Every engine reports a real dependency + weight verdict, never the old
        # blanket "unchecked", and missing weights are named for diagnosis.
        self.assertEqual(set(health['models']),
                         {'ace_step', 'muscriptor', 'minimax_music3', 'mlx_rvc', 'sam_audio', 'whisper'})
        self.assertLessEqual(set(health['models'].values()),
                             {'ready', 'weights_missing', 'unavailable'})
        for engine, status in health['models'].items():
            with self.subTest(engine=engine):
                self.assertEqual(status == 'weights_missing', engine in health['missing_weights'])
                self.assertTrue(health['missing_weights'].get(engine, ['x']))

    def test_health_names_engines_whose_weights_are_absent(self):
        '''A missing artifact must degrade that engine, not the whole service.'''
        absent = {engine: [Path('/nonexistent') / engine] for engine in
                  ('ace_step', 'muscriptor', 'minimax_music3', 'mlx_rvc', 'sam_audio', 'whisper')}
        with patch('local_inference.engines.required_weight_paths', return_value=absent):
            health = self.client.get('/v1/health').json()
        self.assertEqual(health['status'], 'ready')
        self.assertEqual(set(health['missing_weights']), set(absent))
        for engine, status in health['models'].items():
            with self.subTest(engine=engine):
                # Dependencies resolve here, so every engine reports the weight gap.
                self.assertIn(status, {'weights_missing', 'unavailable'})


if __name__ == '__main__':
    unittest.main()
