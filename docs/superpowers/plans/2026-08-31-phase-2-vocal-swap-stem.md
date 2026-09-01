# Phase 2 Vocal Swap Stem Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert one Logic-prepared vocal stem into a selected private target voice, returning one WAV with durable provenance.

**Architecture:** A new private `vocal-swap` worker provides an Applio/RVC-compatible conversion boundary. The gateway owns the public voice list and a `vocal_swap` durable job; the macOS app adds a source-first mode that uses existing upload, cancellation, reattachment, and Library import paths.

**Tech Stack:** Swift 6/SwiftUI/Testing; FastAPI/Pydantic/pytest; Docker Compose; private Applio/RVC-compatible worker.

**Spec:** `docs/superpowers/specs/2026-08-31-phase-2-vocal-swap-stem-design.md`

## Global Constraints

- Backend, Docker, and Compose changes happen on `lts1` under `~/apps/micromix`; native work happens on this Mac.
- Accept one prepared vocal stem only. Do not build song splitting, a mixer, accompaniment upload, or a preview mix.
- Keep voice models and manifests in ignored server data. Public records contain only ID, label, and revision.
- Return exactly one `converted_vocal` WAV. Provenance includes source, voice ID/label, model revision, and fixed profile revision.
- Begin every behavior change with a failing test. Do not claim subjective voice quality from automated tests.

---

## File structure

- Create `services/vocal-swap/`: worker package, manifest, converter protocol, FastAPI app, tests, Dockerfile.
- Modify `services/micromix-api/micromix_api/{models,config,adapters,coordinator,main}.py` and matching tests.
- Create `MacOS/sources/VocalSwap/{VocalSwapViewModel,VocalSwapScreen}.swift` and `MacOS/Tests/VocalSwap/VocalSwapViewModelTests.swift`.
- Modify native models/API/protocols, `MicromixApp.swift`, `DeviceWindow.swift`, Core API tests, and device tests.

### Task 1: Implement the private voice manifest

**Files:**
- Create: `services/vocal-swap/pyproject.toml`, `vocal_swap_worker/{models,manifest,converter}.py`, `tests/test_manifest.py`

**Produces:** `VoiceRecord(id, label, revision)`, `VoiceManifest.enabled_voices()`, `VoiceManifest.resolve(id)`, and `VocalConverter.convert(source_path, voice, destination_path)`.

- [ ] **Step 1: Write failing tests**

~~~python
def test_enabled_voices_hide_model_paths_and_disabled_entries(tmp_path):
    manifest = VoiceManifest.load(write_manifest(tmp_path, [
        {"id": "studio", "label": "Studio Voice", "revision": "rvc-v1", "enabled": True, "model_path": "studio.pth"},
        {"id": "old", "label": "Old Voice", "revision": "rvc-v0", "enabled": False, "model_path": "old.pth"},
    ]))
    assert manifest.enabled_voices() == [VoiceRecord("studio", "Studio Voice", "rvc-v1")]

def test_disabled_voice_cannot_resolve(tmp_path):
    with pytest.raises(UnknownVoiceError):
        VoiceManifest.load(write_manifest(tmp_path, disabled_voice())).resolve("old")
~~~

- [ ] **Step 2: Verify RED on lts1**

~~~bash
cd ~/apps/micromix/services/vocal-swap
uv run --group dev python -m pytest tests/test_manifest.py -q
~~~

Expected: missing manifest module/types.

- [ ] **Step 3: Implement minimal manifest validation**

Load `VOCAL_SWAP_VOICES_ROOT/voices.json`. Require nonblank ID, label, revision, enabled flag, and a model path contained by the voice root. Return public `VoiceRecord` values only; preserve model path privately for conversion.

- [ ] **Step 4: Verify GREEN and commit**

~~~bash
uv run --group dev python -m pytest tests/test_manifest.py -q
git add services/vocal-swap
git commit -m "feat(vocal-swap): add private voice manifest contract"
~~~

### Task 2: Implement the worker conversion service

**Files:**
- Create: `services/vocal-swap/vocal_swap_worker/main.py`, `services/vocal-swap/tests/test_api.py`, `services/vocal-swap/Dockerfile`
- Modify: `.gitignore`

**Produces:** `GET /v1/voices`, `POST /v1/conversions`, `GET /v1/conversions/{id}`, and `POST /v1/conversions/{id}/cancel`.

- [ ] **Step 1: Write the failing worker lifecycle test**

~~~python
async def test_conversion_returns_one_wav_for_enabled_voice(tmp_path):
    app = create_app(manifest=studio_manifest(tmp_path), converter=FakeConverter())
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        accepted = await client.post("/v1/conversions", json={
            "source_path": str(source_wav(tmp_path)), "target_voice_id": "studio"
        })
        result = await client.get(f"/v1/conversions/{accepted.json()['id']}")
    assert result.json()["state"] == "succeeded"
    assert result.json()["output"]["media_type"] == "audio/wav"
~~~

- [ ] **Step 2: Verify RED**

~~~bash
cd ~/apps/micromix/services/vocal-swap
uv run --group dev python -m pytest tests/test_api.py::test_conversion_returns_one_wav_for_enabled_voice -q
~~~

- [ ] **Step 3: Implement the smallest service**

Maintain in-process records with `queued/running/succeeded/failed/cancelled`. Reject an unknown voice with HTTP 422 without calling the converter. Invoke the injected converter once, reject empty/non-WAV output, and never return a private filesystem path.

- [ ] **Step 4: Add and pass edge cases**

~~~python
async def test_unknown_voice_does_not_start_converter(tmp_path: Path):
    converter = FakeConverter()
    response = await post_conversion(create_app(studio_manifest(tmp_path), converter), "missing")
    assert response.status_code == 422 and converter.calls == []

async def test_cancelled_conversion_has_no_output(tmp_path: Path):
    task = await submit_blocked_conversion(create_app(studio_manifest(tmp_path), BlockingConverter()))
    assert (await cancel(task)).json()["state"] == "cancelled"
    assert (await lookup(task)).json()["output"] is None

async def test_non_wav_output_fails_job(tmp_path: Path):
    task = await submit_conversion(create_app(studio_manifest(tmp_path), TextOutputConverter()))
    assert (await lookup(task)).json()["state"] == "failed"
~~~

~~~bash
uv run --group dev python -m pytest -q
~~~

- [ ] **Step 5: Ignore private data and commit**

Ignore `data/vocal-swap/` and `services/vocal-swap/.venv/`.

~~~bash
git add .gitignore services/vocal-swap
git commit -m "feat(vocal-swap): expose conversion worker"
~~~

### Task 3: Add gateway contracts and durable job creation

**Files:**
- Modify: `services/micromix-api/micromix_api/{models,config,main}.py`
- Modify: `services/micromix-api/tests/{test_api,test_generation}.py`

**Produces:** `JobKind.vocal_swap`, `VoiceRecord`, `VoicesResponse`, `VocalSwapRequest(source_asset_id, target_voice_id)`, `GET /v1/voices`, and `POST /v1/jobs/vocal-swap`.

- [ ] **Step 1: Write failing route tests**

~~~python
async def test_vocal_swap_creates_job_with_one_named_vocal_input(client, uploaded_audio):
    response = await client.post("/v1/jobs/vocal-swap", json={
        "source_asset_id": uploaded_audio["id"], "target_voice_id": "studio"
    })
    assert response.status_code == 202
    assert response.json()["kind"] == "vocal_swap"
    assert response.json()["inputs"][0]["name"] == "vocal"
    assert response.json()["parameters"]["target_voice_id"] == "studio"

async def test_vocal_swap_rejects_missing_or_non_audio_source(client):
    missing = await client.post("/v1/jobs/vocal-swap", json={"source_asset_id": "missing", "target_voice_id": "studio"})
    midi = await client.post("/v1/jobs/vocal-swap", json={"source_asset_id": (await upload_midi(client))["id"], "target_voice_id": "studio"})
    assert missing.status_code == 422 and midi.status_code == 422
~~~

- [ ] **Step 2: Verify RED with the pinned API environment**

~~~bash
cd ~/apps/micromix
docker run --rm -v "$PWD/services/micromix-api:/app" -w /app ghcr.io/astral-sh/uv:0.7.22-python3.12-bookworm uv run --frozen --group dev python -m pytest tests/test_api.py -q
~~~

Expected: route 404 and absent types.

- [ ] **Step 3: Implement typed validation and atomic input binding**

Use the existing stored-audio validator and create the job with `InputAssetBinding(name="vocal", position=0, asset_id=source_asset_id)`. Persist only operation, target voice ID/label, model revision, and profile revision. Do not persist or return model paths.

- [ ] **Step 4: Verify GREEN and commit**

Run Step 2, then:

~~~bash
git add services/micromix-api/micromix_api services/micromix-api/tests
git commit -m "feat(api): add durable vocal swap contract"
~~~

### Task 4: Connect worker adapter, polling, cancellation, and recovery

**Files:**
- Modify: `services/micromix-api/micromix_api/{adapters,coordinator,main}.py`
- Modify: `services/micromix-api/tests/{test_adapters,test_coordinator}.py`

**Produces:** `VocalSwapClient.voices(), submit(source_path, voice_id), poll(id), cancel(id), download(output)` and `Coordinator.run_job` support for `vocal_swap`.

- [ ] **Step 1: Write failing adapter tests**

~~~python
async def test_vocal_swap_client_posts_source_path_and_voice(tmp_path):
    client = VocalSwapClient(base_url="http://worker", http_client=recording_http_client(task_id="swap-1"))
    assert await client.submit(tmp_path / "vocal.wav", "studio") == "swap-1"
    assert recorded_json == {"source_path": str(tmp_path / "vocal.wav"), "target_voice_id": "studio"}

async def test_vocal_swap_client_rejects_non_wav_output(tmp_path):
    client = VocalSwapClient(base_url="http://worker", http_client=completed_http_client(media_type="audio/mpeg"))
    with pytest.raises(UpstreamError, match="audio/wav"):
        await client.download(await client.poll("swap-1"))
~~~

- [ ] **Step 2: Verify RED**

Run Task 3's pinned command narrowed to `tests/test_adapters.py`. Expected: `VocalSwapClient` absent.

- [ ] **Step 3: Implement one-output durable execution**

Acquire/release the existing GPU lease, store upstream ID before polling, use existing one-time recovery, download exactly one WAV, and atomically register `OutputAssetBinding(name="converted_vocal", position=0, asset=staged_asset)`.

- [ ] **Step 4: Add failing coordinator tests**

~~~python
async def test_vocal_swap_registers_one_named_wav_and_provenance(store):
    job = await create_vocal_swap_job(store, voice_id="studio")
    await coordinator.run_job(job.id)
    assert (await store.get_job(job.id)).outputs[0].name == "converted_vocal"

async def test_cancelled_vocal_swap_publishes_no_output(store):
    job = await create_vocal_swap_job(store, voice_id="studio")
    await store.request_cancel(job.id)
    await coordinator.run_job(job.id)
    assert (await store.get_job(job.id)).outputs == []

async def test_recovered_vocal_swap_resubmits_once_then_fails(store):
    job = await create_vocal_swap_job(store, voice_id="studio", upstream_id="missing")
    await coordinator.run_job(job.id)
    assert fake_vocal_swap.submit_count == 1
~~~

- [ ] **Step 5: Verify GREEN and commit**

~~~bash
cd ~/apps/micromix
docker run --rm -v "$PWD/services/micromix-api:/app" -w /app ghcr.io/astral-sh/uv:0.7.22-python3.12-bookworm uv run --frozen --group dev python -m pytest tests/test_adapters.py tests/test_coordinator.py -q
git add services/micromix-api/micromix_api services/micromix-api/tests
git commit -m "feat(api): run durable vocal swap jobs"
~~~

### Task 5: Deploy the private worker

**Files:**
- Modify: `docker-compose.yml`, `README.md`, `services/micromix-api/micromix_api/main.py`, `services/micromix-api/tests/test_api.py`

**Produces:** internal worker URL `http://vocal-swap:8903`; read-only private voice root and isolated worker output root.

- [ ] **Step 1: Write the failing voice-list test**

~~~python
async def test_voice_list_returns_only_enabled_public_records(client):
    response = await client.get("/v1/voices")
    assert response.json() == {
        "voices": [{"id": "studio", "label": "Studio Voice", "revision": "rvc-v1"}]
    }
~~~

- [ ] **Step 2: Verify RED and wire Compose**

Run Task 3's pinned API command narrowed to this test; then add the worker service, `VOCAL_SWAP_URL`, health wiring, and ignored-manifest documentation. Do not add credentials or model download instructions.

- [ ] **Step 3: Verify deployment and commit**

~~~bash
cd ~/apps/micromix
docker compose up -d --build
docker compose ps
curl --fail http://localhost:8902/v1/health
curl --fail http://localhost:8902/v1/voices
git add docker-compose.yml README.md services/micromix-api
git commit -m "feat(infra): deploy private vocal swap worker"
git push origin main
~~~

### Task 6: Implement native typed transport and lifecycle

**Files:**
- Modify: `MacOS/sources/Core/{Models,MicromixAPI,ServiceProtocols}.swift`, `MacOS/Tests/Core/MicromixAPITests.swift`
- Create: `MacOS/sources/VocalSwap/VocalSwapViewModel.swift`, `MacOS/Tests/VocalSwap/VocalSwapViewModelTests.swift`

**Produces:** `VocalSwapVoice`, `VocalSwapRequest`, `MicromixAPI.voices()`, `submitVocalSwap()`, `DurableVocalSwapSubmitting`, and a view model with `loadVoices/select/start/cancel`.

- [ ] **Step 1: Write the failing Swift transport test**

~~~swift
@Test("vocal swap loads voices then posts a typed request")
func vocalSwapTransport() async throws {
    MockURLProtocol.handler = { request in
        if request.url?.path == "/v1/voices" {
            return jsonResponse(#"{"voices":[{"id":"studio","label":"Studio Voice","revision":"rvc-v1"}]}"#)
        }
        #expect(request.url?.path == "/v1/jobs/vocal-swap")
        #expect(jsonBody(request)["source_asset_id"] as? String == "asset-vocal")
        #expect(jsonBody(request)["target_voice_id"] as? String == "studio")
        return acceptedJobResponse(kind: "vocal_swap")
    }
    let api = makeAPI()
    #expect(try await api.voices().map(\.id) == ["studio"])
    _ = try await api.submitVocalSwap(.init(sourceAssetID: "asset-vocal", targetVoiceID: "studio"))
}
~~~

- [ ] **Step 2: Verify RED**

~~~bash
cd MacOS
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/MicromixAPITests
~~~

- [ ] **Step 3: Implement seams and write lifecycle tests**

Reuse Reimagine's bounded source reader and JobReattacher. Snapshot source asset and selected voice before upload/submission.

~~~swift
@Test("vocal swap captures source and voice before durable submission")
func startCapturesSourceAndVoice() async throws {
    let viewModel = makeViewModel()
    viewModel.select(url: fixtureVocalURL)
    viewModel.selectedVoiceID = "studio"
    #expect(viewModel.start())
    viewModel.selectedVoiceID = "other"
    #expect(await fakeAPI.submittedVoiceID == "studio")
}

@Test("vocal swap requires a source and voice")
func validation() async throws {
    let viewModel = makeViewModel()
    #expect(!viewModel.start())
    viewModel.select(url: fixtureVocalURL)
    #expect(!viewModel.start())
}

@Test("cancelling vocal swap forwards accepted job ID")
func cancellation() async throws {
    let viewModel = makeViewModel(acceptedJobID: "swap-1")
    viewModel.select(url: fixtureVocalURL)
    viewModel.selectedVoiceID = "studio"
    #expect(viewModel.start())
    await waitForSubmission()
    viewModel.cancel()
    #expect(await fakeAPI.cancelledJobID == "swap-1")
}
~~~

- [ ] **Step 4: Implement minimal lifecycle, verify GREEN, and commit**

~~~bash
cd MacOS
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS' -only-testing:MicromixTests/MicromixAPITests -only-testing:MicromixTests/VocalSwapViewModelTests
git add MacOS/sources/Core MacOS/sources/VocalSwap MacOS/Tests/Core/MicromixAPITests.swift MacOS/Tests/VocalSwap
git commit -m "feat(macos): add durable vocal swap lifecycle"
~~~

### Task 7: Add the mode UI and integration checks

**Files:**
- Create: `MacOS/sources/VocalSwap/VocalSwapScreen.swift`
- Modify: `MacOS/sources/App/{MicromixApp,DeviceWindow}.swift`, `MacOS/Tests/App/DeviceWindowTests.swift`, `docs/MICROMIX_ROADMAP.md`, `README.md`

**Produces:** `DeviceMode.vocalSwap` and `VocalSwapScreen(viewModel:serverAvailable:)`. Completion selects Library result; it does not control Finder, Logic, or desktop UI.

- [ ] **Step 1: Write the failing layout test**

~~~swift
@Test("Vocal Swap mode shows source, target voice, and primary action")
func vocalSwapModeLayout() throws {
    let hierarchy = try renderDevice(mode: .vocalSwap)
    #expect(hierarchy.contains("SELECT VOCAL STEM"))
    #expect(hierarchy.contains("TARGET VOICE"))
    #expect(hierarchy.contains("SWAP VOCAL"))
}
~~~

- [ ] **Step 2: Verify RED, implement, and verify all native tests**

Add mode selector/status/routing and a compact screen containing only stem selection, target picker, progress, cancel, and Library result action. Disable source/voice changes while running.

~~~bash
cd MacOS
xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'
~~~

- [ ] **Step 3: Commit, synchronize, and stop for manual acceptance**

Update roadmap/README to state one prepared stem in and one WAV out; manual bilingual quality evaluation remains required.

~~~bash
git add MacOS docs/MICROMIX_ROADMAP.md README.md
git commit -m "feat(macos): add vocal swap mode"
git push origin main
~~~

On `lts1`, inspect status, `git pull --ff-only`, and rebuild Compose. Then stop for manual acceptance: choose a prepared stem, select a private voice, submit/cancel once, confirm Library provenance, and import the WAV into Logic.
