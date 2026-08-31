from fastapi.testclient import TestClient

from muscriptor_worker.main import ModelManager, create_app


class FakeEngine:
    instruments = ["Piano", "Drums"]

    def __init__(self):
        self.calls = []
        self.released = False

    def transcribe(self, data: bytes, instruments: list[str], detect_tempo: str) -> bytes:
        self.calls.append((data, instruments, detect_tempo))
        return b"MThd-midi"

    def release(self) -> None:
        self.released = True


def test_worker_is_cold_until_first_transcription():
    engine = FakeEngine()
    manager = ModelManager(lambda: engine)

    with TestClient(create_app(manager)) as client:
        assert client.get("/health").json() == {"status": "ok", "loaded": False}
        response = client.post(
            "/transcribe/midi",
            files={"audio_file": ("song.wav", b"RIFF-audio", "audio/wav")},
            data={"instruments": "Piano", "detect_tempo": "best-effort"},
        )

        assert response.status_code == 200
        assert response.content == b"MThd-midi"
        assert response.headers["content-type"] == "audio/midi"
        assert engine.calls == [(b"RIFF-audio", ["Piano"], "best-effort")]
        assert client.get("/health").json()["loaded"] is True


def test_release_drops_loaded_model_and_is_idempotent():
    engines = []

    def factory():
        engine = FakeEngine()
        engines.append(engine)
        return engine

    manager = ModelManager(factory)
    with TestClient(create_app(manager)) as client:
        client.post(
            "/transcribe/midi",
            files={"audio_file": ("song.wav", b"audio", "audio/wav")},
        )
        first = client.post("/api/gpu/release")
        second = client.post("/api/gpu/release")

        assert first.json() == {"released": True}
        assert second.json() == {"released": False}
        assert engines[0].released is True
        assert client.get("/health").json()["loaded"] is False


def test_instruments_do_not_force_gpu_model_load():
    engine = FakeEngine()
    manager = ModelManager(lambda: engine, instrument_provider=lambda: engine.instruments)

    with TestClient(create_app(manager)) as client:
        assert client.get("/instruments").json() == {"instruments": ["Piano", "Drums"]}
        assert client.get("/health").json()["loaded"] is False
