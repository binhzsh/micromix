# PLAN: Library playback and simple multitrack editing

## Context
The user approved a simple local multitrack editor, overriding the prior roadmap exclusion. Preserve the pre-existing uncommitted `PLAN.md` change. This plan tracks this increment separately.

## Tasks
- [ ] 1. Add library audio transport and waveform seeking.
  - Status: in-progress; implementation awaits final headless and user visual/audio verification.
- [ ] 2. Add a simple non-destructive multitrack timeline with synchronized audition and basic trimming/stacking.
  - Status: in-progress; temporary numeric editing and audition implemented; persistence, export, direct manipulation, and manual playback verification remain.
- [ ] 3. Verify and reconcile roadmap and document limitations.
  - Status: in-progress; roadmap exception added, full tests and manual checks pending.

## Log
- 2026-11-12: User selected the simple editor direction. Existing dirty `PLAN.md` preserved; `git fetch origin` and `git pull --ff-only` completed, already up to date. Stem-split quality remains unresolved separately.
- 2026-11-12: Full native headless suite passed: 152 tests in 25 suites. Timeline is an in-memory audition prototype with numeric edits, no project persistence or mix export; visual and audible checks are still user-led.
