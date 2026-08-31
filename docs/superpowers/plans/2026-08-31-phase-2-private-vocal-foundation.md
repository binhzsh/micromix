# Phase 2 Private Vocal Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a private, durable, server-only voice-conversion foundation that can later power Vocal Swap without exposing an untested native workflow.

**Architecture:** The gateway owns durable jobs, private profile validation, GPU lease lifecycle, and output registration. An internal RVC worker receives only a source file and resolved profile ID from a mounted private model root, writes a scoped WAV, and remains invisible to the macOS app until quality evaluation approves the workflow.

**Tech Stack:** Python 3.12, FastAPI, Pydantic, httpx, Docker Compose, pytest, RVC worker runtime, existing GPU router.

**Spec:** `docs/superpowers/specs/2026-08-31-phase-2-private-vocal-foundation-design.md`

## Global Constraints

- Backend code and Compose changes run only on `lts1`.
- The worker remains internal; do not add a macOS Vocal Swap screen in this increment.
- Voice profiles and model weights are private, ignored local data; never commit them.
- WAV is the only output format.
- Do not add training, LoRA/style-adapter, public sharing, model browsing, or source separation in this increment.
- Use the gateway—not the worker—as the durable job/state/provenance authority.
- Follow red-green-refactor for every production behavior.

---

### Task 1: Model the private conversion contract

**Files:**
- Modify: `services/micromix-api/micromix_api/models.py`
- Modify: `services/micromix-api/micromix_api/config.py`
- Test: `services/micromix-api/tests/test_api.py`

**Interfaces:**
- Produces `JobKind.vocal_conversion`.
- Produces `VocalConversionRequest(source_asset_id: str, voice_profile_id: str, pitch_shift_semitones: int = 0, f0_method: Literal["rmvpe"] = "rmvpe")`.
- Produces `Settings.voice_profile_root: Path` from `VOICE_PROFILE_ROOT`.

- [ ] **Step 1: Write failing API validation tests**

```python
@pytest.mark.asyncio
async def test_vocal_conversion_rejects_out_of_range_pitch(client):
    response = await client.post("/v1/jobs/vocal-conversion", json={
        "source_asset_id": "asset-1", "voice_profile_id": "private-voice",
        "pitch_shift_semitones": 25,
    })
    assert response.status_code == 422
```

- [ ] **Step 2: Run the focused test and confirm it fails because the route/model is absent**

Run: `python -m pytest tests/test_api.py -k vocal_conversion -q`

- [ ] **Step 3: Add job kind, request model, and settings path**

```python
class JobKind(str, Enum):
    generation = "generation"
    transcription = "transcription"
    vocal_conversion = "vocal_conversion"

class VocalConversionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    source_asset_id: str = Field(min_length=1)
    voice_profile_id: str = Field(pattern=r"^[a-z0-9][a-z0-9-]{0,63}$")
    pitch_shift_semitones: int = Field(default=0, ge=-24, le=24)
    f0_method: Literal["rmvpe"] = "rmvpe"
```

- [ ] **Step 4: Run focused model tests and commit**

Run: `python -m pytest tests/test_api.py -k vocal_conversion -q`

Commit: `feat(api): define private vocal conversion contract`

### Task 2: Add a private voice-profile registry

**Files:**
- Create: `services/micromix-api/micromix_api/voice_profiles.py`
- Test: `services/micromix-api/tests/test_voice_profiles.py`

**Interfaces:**
- Produces `VoiceProfile(id: str, display_name: str, revision: str, model_path: Path, index_path: Path | None)`.
- Produces `VoiceProfileRegistry(root: Path).resolve(profile_id: str) -> VoiceProfile`.
- Registry reads only `<root>/profiles.json` and verifies every resolved path remains beneath `root`.

- [ ] **Step 1: Write failing registry tests**

```python
def test_registry_resolves_profile_with_immutable_revision(tmp_path):
    (tmp_path / "models").mkdir()
    (tmp_path / "models" / "voice.pth").write_bytes(b"weights")
    (tmp_path / "profiles.json").write_text(json.dumps({"profiles": [{
        "id": "private-voice", "display_name": "Private Voice", "revision": "r1",
        "model": "models/voice.pth",
    }]}))
    assert VoiceProfileRegistry(tmp_path).resolve("private-voice").revision == "r1"
```

- [ ] **Step 2: Run the focused test and confirm import failure**

Run: `python -m pytest tests/test_voice_profiles.py -q`

- [ ] **Step 3: Implement strict manifest parsing and containment checks**

```python
def _contained(root: Path, relative: str) -> Path:
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise VoiceProfileError("profile path escapes private model root")
    if not path.is_file():
        raise VoiceProfileError("profile model is unavailable")
    return path
```

- [ ] **Step 4: Run focused tests and commit**

Run: `python -m pytest tests/test_voice_profiles.py -q`

Commit: `feat(api): add private voice profile registry`

### Task 3: Expose durable gateway submission without leaking paths

**Files:**
- Modify: `services/micromix-api/micromix_api/main.py`
- Modify: `services/micromix-api/micromix_api/coordinator.py`
- Modify: `services/micromix-api/micromix_api/models.py`
- Test: `services/micromix-api/tests/test_api.py`
- Test: `services/micromix-api/tests/test_coordinator.py`

**Interfaces:**
- Consumes `VoiceProfileRegistry.resolve` and `VocalConversionRequest`.
- Produces `POST /v1/jobs/vocal-conversion` with a `source` input link.
- Stores only `voice_profile_id`, `voice_profile_revision`, `pitch_shift_semitones`, and `f0_method` in public job parameters.
- Stores resolved source/profile paths only in excluded internal parameters.

- [ ] **Step 1: Write failing API test for durable submission/provenance**

```python
response = await client.post("/v1/jobs/vocal-conversion", json={
    "source_asset_id": source.id, "voice_profile_id": "private-voice",
})
assert response.status_code == 202
assert response.json()["parameters"]["voice_profile_revision"] == "r1"
assert "model_path" not in response.json()["parameters"]
```

- [ ] **Step 2: Run focused test and confirm it fails**

Run: `python -m pytest tests/test_api.py -k vocal_conversion -q`

- [ ] **Step 3: Implement submission and dispatcher routing**

```python
job = await store.create_job(
    JobKind.vocal_conversion,
    {"voice_profile_id": profile.id, "voice_profile_revision": profile.revision,
     "pitch_shift_semitones": payload.pitch_shift_semitones, "f0_method": payload.f0_method,
     "_source_path": str(source_path), "_model_path": str(profile.model_path)},
    inputs=[InputAssetBinding(payload.source_asset_id, "source")],
)
```

- [ ] **Step 4: Run focused tests and commit**

Run: `python -m pytest tests/test_api.py tests/test_coordinator.py -k vocal_conversion -q`

Commit: `feat(api): submit durable vocal conversion jobs`

### Task 4: Create the internal RVC worker boundary

**Files:**
- Create: `services/rvc-worker/Dockerfile`
- Create: `services/rvc-worker/requirements.txt`
- Create: `services/rvc-worker/app.py`
- Create: `services/rvc-worker/tests/test_app.py`
- Modify: `docker-compose.yml`

**Interfaces:**
- Produces `GET /health` returning `{"status":"ready"}` or `{"status":"cold"}`.
- Produces `POST /convert` accepting `{source_path, model_path, index_path, output_path, pitch_shift_semitones, f0_method}`.
- Source, model, and output paths are validated as mounted, contained paths; output is a WAV under the gateway job directory.
- Worker does not acquire GPU or persist job state.

- [ ] **Step 1: Write failing worker route tests**

```python
def test_convert_rejects_source_outside_mounted_assets(client):
    response = client.post("/convert", json={"source_path": "/etc/passwd", ...})
    assert response.status_code == 422
```

- [ ] **Step 2: Run tests and confirm the worker does not exist**

Run: `python -m pytest services/rvc-worker/tests/test_app.py -q`

- [ ] **Step 3: Implement the contained-path FastAPI worker and pinned RVC runtime image**

```dockerfile
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pip ffmpeg git
RUN git clone --depth 1 https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI.git /opt/rvc
```

- [ ] **Step 4: Add Compose mounts and internal networking**

```yaml
rvc-worker:
  build: { context: ./services/rvc-worker }
  volumes:
    - ${MICROMIX_DATA_ROOT:-./data}/gateway:/data
    - ${VOICE_PROFILE_ROOT:-/mnt/fast_pool/fast_models/micromix/voices}:/voices:ro
  networks: [default, shared_net]
```

- [ ] **Step 5: Run worker unit tests and commit**

Run: `python -m pytest services/rvc-worker/tests/test_app.py -q`

Commit: `feat(rvc): add internal conversion worker`

### Task 5: Connect coordinator, GPU router, and output integrity

**Files:**
- Modify: `services/micromix-api/micromix_api/adapters.py`
- Modify: `services/micromix-api/micromix_api/coordinator.py`
- Modify: `services/micromix-api/micromix_api/main.py`
- Modify: `services/micromix-api/micromix_api/config.py`
- Test: `services/micromix-api/tests/test_adapters.py`
- Test: `services/micromix-api/tests/test_coordinator.py`

**Interfaces:**
- Produces `RVCClient.convert(...) -> Path` and `RVCClient.health() -> str`.
- `Coordinator._run_vocal_conversion` acquires `micromix-rvc` for 8,000 MiB, invokes the worker, validates a nonempty WAV, writes/registers `converted-vocal.wav`, and always releases the GPU.

- [ ] **Step 1: Write failing client/coordinator tests**

```python
assert gpu.calls == [("micromix-rvc", 8_000, 60)]
assert completed.outputs[0].name == "converted-vocal"
assert completed.outputs[0].asset.filename == "converted-vocal.wav"
assert gpu.releases == ["micromix-rvc"]
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `python -m pytest tests/test_adapters.py tests/test_coordinator.py -k vocal_conversion -q`

- [ ] **Step 3: Implement the client and coordinator branch**

```python
if job.kind is JobKind.vocal_conversion:
    await self._run_vocal_conversion(job)
```

- [ ] **Step 4: Run gateway suite and commit**

Run: `python -m pytest tests -q`

Commit: `feat(api): run private vocal conversion jobs`

### Task 6: Record the gated foundation and verify the server contract

**Files:**
- Modify: `docs/MICROMIX_ROADMAP.md`
- Modify: `docs/superpowers/plans/2026-08-31-phase-2-private-vocal-foundation.md`

- [ ] **Step 1: Mark the server foundation active but retain the manual quality gate**

```markdown
Phase 2 foundation is available only to private, authorized profiles.
Native Vocal Swap remains withheld until English/Vietnamese evaluation passes.
```

- [ ] **Step 2: Run backend tests, build the worker image, and check health**

Run on `lts1`:

```bash
docker compose build rvc-worker micromix-api
docker compose up -d rvc-worker micromix-api
curl --fail http://localhost:8902/v1/health
```

- [ ] **Step 3: Verify missing-profile rejection without using audio or a real voice model**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'content-type: application/json' \
  -d '{"source_asset_id":"missing","voice_profile_id":"private-voice"}' \
  http://localhost:8902/v1/jobs/vocal-conversion
```

- [ ] **Step 4: Commit, merge, push, and fast-forward both checkouts**

Commit: `feat(voice): establish private vocal conversion foundation`

## Plan self-review

- Spec coverage: Tasks 1–5 implement the contract, private registry, worker,
  durability, GPU lifecycle, output integrity, and provenance. Task 6 records
  the explicit quality gate.
- No placeholders: every implementation task names concrete files, interfaces,
  commands, and assertions.
- Type consistency: the gateway contract uses `voice_profile_id`,
  `voice_profile_revision`, `pitch_shift_semitones`, `f0_method`, and the
  `converted-vocal` output name throughout.
