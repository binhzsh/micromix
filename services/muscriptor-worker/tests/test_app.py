import wave

from fastapi.testclient import TestClient

from muscriptor_worker import main
from muscriptor_worker.main import ModelManager, available_instruments, create_app


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


def test_release_schedules_worker_restart_to_drop_cuda_context(monkeypatch):
    engine = FakeEngine()
    restarts = []
    monkeypatch.setenv("MUSCRIPTOR_RESTART_AFTER_RELEASE", "1")
    monkeypatch.setattr(
        main,
        "schedule_process_restart",
        lambda: restarts.append(True),
        raising=False,
    )

    with TestClient(create_app(ModelManager(lambda: engine))) as client:
        client.post(
            "/transcribe/midi",
            files={"audio_file": ("song.wav", b"audio", "audio/wav")},
        )
        first = client.post("/api/gpu/release")
        second = client.post("/api/gpu/release")

    assert first.json() == {"released": True}
    assert second.json() == {"released": False}
    assert restarts == [True]


def test_instruments_do_not_force_gpu_model_load():
    engine = FakeEngine()
    manager = ModelManager(lambda: engine, instrument_provider=lambda: engine.instruments)

    with TestClient(create_app(manager)) as client:
        assert client.get("/instruments").json() == {"instruments": ["Piano", "Drums"]}
        assert client.get("/health").json()["loaded"] is False


def test_default_instruments_do_not_import_muscriptor(monkeypatch):
    original_import = __import__

    def guarded_import(name, *args, **kwargs):
        if name == "muscriptor" or name.startswith("muscriptor."):
            raise AssertionError("capability discovery must not initialize MuScriptor")
        return original_import(name, *args, **kwargs)

    monkeypatch.setattr("builtins.__import__", guarded_import)

    instruments = available_instruments()

    assert instruments[0] == "acoustic_bass"
    assert instruments[-1] == "voice"
    assert len(instruments) == 35


def test_false_tempo_form_reaches_engine_as_boolean_false():
    engine = FakeEngine()

    with TestClient(create_app(ModelManager(lambda: engine))) as client:
        response = client.post(
            "/transcribe/midi",
            files={"audio_file": ("song.wav", b"RIFF-audio", "audio/wav")},
            data={"detect_tempo": "false"},
        )

    assert response.status_code == 200
    assert engine.calls == [(b"RIFF-audio", [], False)]


def test_audio_decode_falls_back_to_ffmpeg_after_native_readers_fail():
    transcoded = []

    def wav_reader(stream):
        payload = stream.read()
        if payload == b"m4a-audio":
            raise wave.Error("not wav")
        assert payload == b"RIFF-converted"
        return [0.25], 16_000

    def other_reader(stream):
        assert stream.read() == b"m4a-audio"
        raise RuntimeError("format not recognised")

    def transcode(data):
        transcoded.append(data)
        return b"RIFF-converted"

    result = main.decode_audio(
        b"m4a-audio",
        wav_reader=wav_reader,
        other_reader=other_reader,
        transcode=transcode,
    )

    assert result == ([0.25], 16_000)
    assert transcoded == [b"m4a-audio"]
