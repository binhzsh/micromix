# Phase 1A Bilingual Generation Controls Design

**Date:** 2026-08-31

**Status:** approved for implementation

**Scope:** give Generate the high-value, reproducible musical controls already
available to Reference generation, add explicit English/Vietnamese vocal intent,
and retain every selected value in durable job provenance.

## Product behavior

Generate becomes a concise creative surface with one visible language picker and
one compact musical-options disclosure. The visible picker offers `Auto`,
`English`, and `Vietnamese`; `Auto` omits the server field so ACE-Step keeps its
current automatic behavior. The disclosure contains alternatives, seed, BPM,
key, and time signature. Empty optional values are omitted rather than sent as
fake defaults.

The normal user path remains prompt/lyrics, language, duration, quality, and
Generate. The additional controls exist for reproducible or intentionally
constrained renders, not for exposing model internals.

Reference generation receives the same language picker because ACE-Step's
text-to-music reference path supports explicit vocal language. Remix and
Repaint do not display a language selector because ACE-Step ignores that setting
for their source transformation task types.

## Server contract

`GenerationControls` adds:

```python
vocal_language: Literal["en", "vi"] | None = None
```

`GenerationRequest` already has `seed`, `variation_count`, `bpm`, `key`, and
`time_signature`; the native client simply begins sending them. The field is
optional, accepts only English and Vietnamese language codes, and is persisted
in the durable job parameter payload unchanged.

`ReferenceGenerationRequest` inherits the new language field. Remix and Repaint
technically inherit it but their native request types never send it, and the ACE
adapter only includes `vocal_language` for `text` and `reference` operations.
This prevents a UI affordance that does nothing.

The ACE adapter forwards valid language intent as `vocal_language`. It continues
to force WAV output; output-format selection is deferred because it changes
asset MIME, extension, download behavior, and Logic-hand-off expectations.

## Native model and transport

Introduce a small, `Sendable` `GenerationOptions` value:

```swift
struct GenerationOptions: Equatable, Sendable {
    var seed: UInt32?
    var variationCount: Int
    var bpm: Int?
    var key: String?
    var timeSignature: String?
    var vocalLanguage: VocalLanguage
}

enum VocalLanguage: String, CaseIterable, Sendable {
    case automatic
    case english
    case vietnamese
    var apiValue: String? { ... }
}
```

`MicromixAPI.generate` and `submitGeneration` gain a `GenerationOptions`
parameter with a default, so existing callers preserve their current behavior.
The JSON body sends `variation_count` always and sends the remaining fields only
when non-nil. `VocalLanguage.automatic` sends no `vocal_language` key.

`GenerateServicing` and `DurableGenerationSubmitting` gain the same options
argument. Fakes and all test seams are updated rather than bypassed.

`ReimagineRequest.reference` gains `vocalLanguage`; request serialization adds
it only for English/Vietnamese.

## Native UI and lifecycle

`GenerateViewModel` owns the GenerationOptions fields in published form and
captures an immutable options value before starting asynchronous submission.
Validation remains bounded and local: variation count 1–4, seed unsigned
32-bit, BPM 30–300, and supported time signatures 2/4, 3/4, 4/4, and 6/8.
The UI uses selection controls and numeric fields that cannot transmit invalid
values. Each accepted job therefore captures and persists the selected options
through the existing durable job and provenance path.

`GenerateScreen` adds a language segmented picker alongside quality/duration
and a collapsed `MUSICAL OPTIONS` group. The primary action remains reachable at
the minimum window size.

`ReimagineViewModel` and `ReimagineScreen` add language only to the Reference
mode. Switching operation never sends a stale language setting to Remix or
Repaint.

## Errors and compatibility

The server rejects unsupported language codes with HTTP 422. Older native
callers remain compatible because all added fields are optional/defaulted. The
existing gateway job parameter persistence carries the new values without a
schema migration. Existing saved library items require no migration.

## Tests

- Python model tests cover valid `en`/`vi`, omission, and rejected codes.
- Adapter tests assert language maps only to text/reference ACE payloads.
- API tests assert Generate's exact JSON body and durable parameter provenance.
- Swift API tests assert omission for Auto and exact body keys for Vietnamese.
- Generate ViewModel tests assert captured options reach both durable and legacy
  service seams and cannot be mutated during a running request.
- Reimagine tests assert language serialization in Reference and absence from
  Remix/Repaint.
- Device layout tests keep the action reachable at default and minimum sizes.

## Deferred

- ACE-Step Complete, Lego, Extract, and output formats.
- More languages and a general language picker.
- Model tuning, thinking controls, LoRAs, and arbitrary inference options.
- Manual quality validation; it remains a pre-release Phase 0 gate.
