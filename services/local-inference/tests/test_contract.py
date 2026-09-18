"""Local API capabilities remain an executable contract, not a model claim."""
import tempfile
import unittest
from pathlib import Path
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

    def test_health_is_local_without_loading_any_model(self):
        health = self.client.get('/v1/health').json()
        self.assertEqual(health['service'], 'micromix-local-inference')
        self.assertEqual(health['status'], 'ready')
        self.assertIn('ace_step', health['models'])
        self.assertIn('muscriptor', health['models'])


if __name__ == '__main__':
    unittest.main()
