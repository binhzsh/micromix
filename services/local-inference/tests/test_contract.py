"""Lightweight API contracts. No model imports, downloads, or inference."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from local_inference import main


class LocalContractTests(unittest.TestCase):
    def setUp(self):
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(patch.object(main, "ASSET_ROOT", Path(temporary)))
        self.enterContext(patch.dict(main._assets, {}, clear=True))
        self.enterContext(patch.dict(main._jobs, {}, clear=True))
        # Exercise validation, upload, submission and job records, but never MLX.
        self.enqueue = self.enterContext(patch.object(main, "_enqueue_job"))
        self.client = self.enterContext(TestClient(main.app))
        uploaded = self.client.post(
            "/v1/assets", files={"audio_file": ("source.wav", b"RIFF", "audio/wav")}
        )
        self.assertEqual(uploaded.status_code, 200, uploaded.text)
        self.source_id = uploaded.json()["id"]

    def routes(self):
        return [
            ("generation", {}),
            ("reference-generation", {"reference_asset_id": self.source_id}),
            ("remix", {"source_asset_id": self.source_id}),
            ("repaint", {
                "source_asset_id": self.source_id,
                "start_seconds": 1, "end_seconds": 11,
            }),
        ]

    def test_advertised_preset_submits_to_every_generation_route(self):
        capabilities = self.client.get("/v1/capabilities").json()
        preset = capabilities["generation_presets"][0]["id"]
        for route, fields in self.routes():
            with self.subTest(route=route):
                response = self.client.post(f"/v1/jobs/{route}", json={
                    "prompt": "warm piano", "lyrics": "hello", "seed": 42,
                    "preset": preset, **fields,
                })
                self.assertEqual(response.status_code, 202, response.text)
                params = response.json()["parameters"]
                self.assertEqual(params["preset"], "minimax-cover")
                self.assertEqual(params["prompt"], "warm piano")
                self.assertEqual(params["lyrics"], "hello")
                self.assertEqual(params["seed"], 42)
                self.assertNotIn("source_strength", params)
                self.assertNotIn("repaint_strength", params)

    def test_unsupported_controls_are_rejected_before_inference(self):
        for route, fields in self.routes():
            unsupported = [("variation_count", 2)]
            if route in ("generation", "reference-generation"):
                unsupported += [
                    ("bpm", 120), ("key", "C minor"),
                    ("time_signature", "4"), ("vocal_language", "vi"),
                ]
            if route == "remix":
                unsupported.append(("source_strength", 0.8))
            if route == "repaint":
                unsupported.append(("repaint_strength", 0.8))
            for field, value in unsupported:
                with self.subTest(route=route, field=field):
                    response = self.client.post(f"/v1/jobs/{route}", json={
                        "prompt": "piano", **fields, field: value,
                    })
                    self.assertEqual(response.status_code, 422, response.text)
                    self.assertEqual(
                        response.json()["detail"][0]["loc"], ["body", field]
                    )
        self.assertEqual(self.client.get("/v1/jobs").json(), [])
        self.enqueue.assert_not_called()

    def test_legacy_presets_record_actual_local_model(self):
        for preset in ["turbo", "quality"]:
            response = self.client.post("/v1/jobs/generation", json={
                "prompt": "piano", "preset": preset,
            })
            self.assertEqual(response.status_code, 202, response.text)
            self.assertEqual(
                response.json()["parameters"]["preset"], "minimax-cover"
            )


if __name__ == "__main__":
    unittest.main()
