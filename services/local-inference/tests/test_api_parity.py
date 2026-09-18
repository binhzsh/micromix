"""API parity checks without loading any model."""
import tempfile
import unittest
from pathlib import Path

from fastapi.testclient import TestClient
from local_inference import main


class APIParityTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.app = main.create_app(self.root, start_worker=False, max_upload_bytes=64)
        self.client = self.enterContext(TestClient(self.app))

    def upload(self, data=b"RIFFsource", filename="source.wav"):
        response = self.client.post('/v1/assets', files={
            'audio_file': (filename, data, 'audio/wav'),
        })
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_all_generation_routes_preserve_controls_and_seeds(self):
        source = self.upload()
        cases = [
            ('generation', {'bpm': 118, 'key': 'A minor', 'time_signature': '4'}),
            ('reference-generation', {'reference_asset_id': source['id'], 'bpm': 118}),
            ('remix', {'source_asset_id': source['id'], 'source_strength': 0.7}),
            ('repaint', {'source_asset_id': source['id'], 'start_seconds': 2,
                         'end_seconds': 12, 'repaint_strength': 0.8}),
        ]
        for route, fields in cases:
            with self.subTest(route=route):
                response = self.client.post('/v1/jobs/' + route, json={
                    'prompt': 'warm piano', 'lyrics': 'xin chào', 'preset': 'quality',
                    'variation_count': 3, 'seed': 4294967295, 'vocal_language': 'vi', **fields,
                })
                self.assertEqual(response.status_code, 202, response.text)
                job = response.json()
                self.assertEqual(job['state'], 'queued')
                self.assertEqual(job['parameters']['seeds'], [4294967295, 0, 1])
                self.assertEqual(job['parameters']['preset'], 'quality')
                self.assertEqual(job['parameters']['vocal_language'], 'vi')
                for field, value in fields.items():
                    if not field.endswith('asset_id'):
                        self.assertEqual(job['parameters'][field], value)
                if route != 'generation':
                    self.assertEqual(job['inputs'][0]['asset']['id'], source['id'])

    def test_upload_limit_and_filename_sanitization(self):
        response = self.client.post('/v1/assets', files={
            'audio_file': ('large.wav', b'x' * 65, 'audio/wav'),
        })
        self.assertEqual(response.status_code, 413)
        asset = self.upload(filename='../../source.wav')
        self.assertEqual(asset['filename'], 'source.wav')
        self.assertEqual(self.client.get(asset['download_url']).content, b'RIFFsource')

    def test_blank_prompt_and_invalid_repaint_are_rejected(self):
        self.assertEqual(self.client.post('/v1/jobs/generation', json={'prompt': '  '}).status_code, 422)
        source = self.upload()
        for start, end in [(0, 2), (0, 91), (10, 5)]:
            response = self.client.post('/v1/jobs/repaint', json={
                'prompt': 'bridge', 'source_asset_id': source['id'],
                'start_seconds': start, 'end_seconds': end,
            })
            self.assertEqual(response.status_code, 422)

    def test_transcription_accepts_repeated_instruments_and_tempo(self):
        response = self.client.post('/v1/jobs/transcription', files=[
            ('audio_file', ('source.wav', b'RIFF', 'audio/wav')),
            ('instruments', (None, 'acoustic_piano')),
            ('instruments', (None, 'organ')),
            ('detect_tempo', (None, 'false')),
        ])
        self.assertEqual(response.status_code, 202, response.text)
        params = response.json()['parameters']
        self.assertEqual(params['instruments'], ['acoustic_piano', 'organ'])
        self.assertIs(params['detect_tempo'], False)

    def test_voice_selection_and_stems_link_source(self):
        root = self.root / 'voice-models'
        root.mkdir(exist_ok=True)
        (root / 'my-voice.safetensors').write_bytes(b'private weights')
        (root / 'my-voice.index').write_bytes(b'private index')
        source = self.upload()
        response = self.client.post('/v1/jobs/vocal-swap', json={
            'source_asset_id': source['id'], 'voice_model': 'my-voice',
        })
        self.assertEqual(response.status_code, 202, response.text)
        job = response.json()
        self.assertEqual(job['parameters']['voice_model'], 'my-voice')
        self.assertTrue(job['parameters']['voice_model_revision'].startswith('sha256:'))
        self.assertNotIn('model_path', job['parameters'])
        self.assertNotIn('source_path', job['parameters'])
        self.assertEqual(job['inputs'][0]['asset']['id'], source['id'])
        response = self.client.post('/v1/jobs/stem-split', json={
            'source_asset_id': source['id'], 'description': 'vocals',
        })
        self.assertEqual(response.status_code, 202, response.text)

    def test_jobs_and_assets_survive_new_app_instance(self):
        asset = self.upload()
        job = self.client.post('/v1/jobs/generation', json={'prompt': 'piano', 'seed': 42}).json()
        self.client.__exit__(None, None, None)
        app = main.create_app(self.root, start_worker=False)
        with TestClient(app) as client:
            self.assertEqual(client.get('/v1/jobs/' + job['id']).json()['parameters']['seed'], 42)
            self.assertEqual(client.get(asset['download_url']).content, b'RIFFsource')

    def test_cancellation_is_idempotent_and_keeps_job_record(self):
        job = self.client.post('/v1/jobs/generation', json={'prompt': 'piano'}).json()
        for _ in range(2):
            response = self.client.post('/v1/jobs/' + job['id'] + '/cancel')
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()['state'], 'cancelled')


if __name__ == '__main__':
    unittest.main()
