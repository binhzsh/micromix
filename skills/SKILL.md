---
name: handoff
description: >
  Pause work and generate a handoff document so a fresh AI agent session
  can pick up exactly where you left off.  Triggers: "/handoff", "create
  handoff", "save state for next session", "prepare handoff", or when
  you say you need to step away and want the next agent to continue.
---

# handoff

Generate a **handoff document** that lets a fresh AI agent continue your
work on the Micromix project without re-reading the entire conversation.

## When to use

- You need to step away and want the next session to resume cleanly.
- You're switching to a different AI agent or model and want context
  preserved.
- You've made partial changes and want the next agent to understand
  state, decisions, and next steps.

## How it works

1. **Gather context** — read the conversation, current git status, open
   files, and any in-progress changes.
2. **Write the handoff** — save a structured document to `$TMPDIR`
   (typically `/var/folders/.../T/` on macOS).  The file is named
   `micromix-handoff-<timestamp>.md` so it's easy to find.
3. **Report the path** — print the full path so you can open it or pass
   it to the next agent.

## Document structure

Every handoff document contains these sections:

### 1. Objective

What are we trying to accomplish right now?  One or two sentences.

### 2. Current State

- **Git status**: branch, dirty files, uncommitted changes.
- **Open files**: which files you were editing and what changed.
- **Build / test state**: did the last build or test pass?  Any known
  failures?
- **Sidecar status**: is the local inference sidecar running?  Health
  check results if relevant.

### 3. What Was Done

A concise list of completed actions in this session: decisions made,
files created/modified, commands run, findings.

### 4. What's Left / Next Steps

Actionable next steps for the next agent.  Prioritized.  Include exact
commands when possible (e.g. `xcodebuild`, `xcodebuild test`, sidecar
commands from AGENTS.md).

### 5. Context & Gotchas

- Architecture decisions that matter (MacOS app + FastAPI sidecar at
  `http://127.0.0.1:8902`).
- Known gaps or TODOs discovered during work.
- Any constraints specific to this project (Apple Silicon only, no
  network dependency, solo-user app).

### 6. Suggested Skills

Which OpenBitFun skills the next agent should consider loading:

| Skill | When to use |
|-------|-------------|
| `review` | After non-trivial implementation — correctness, edge cases |
| `archive` | When a change is finished and artifacts should be preserved |
| `debug` | When a runtime bug needs investigation |
| `plan` | Before starting a new feature or design |
| `commit-push-pr` | When ready to push and create a PR |
| `codegraph` | For structural code questions (callers, callees) |

### 7. References

Paths to relevant files — do **not** duplicate content already in
specs, plans, ADRs, commits, or diffs.  Reference them by path.

Key project files:

- `AGENTS.md` — project conventions, build commands, testing rules
- `README.md` — overview and setup
- `MacOS/` — native macOS SwiftUI app source
- `MacOS/Tests/` — Swift tests
- `services/local-inference/` — FastAPI sidecar
- `scripts/` — operational scripts (health checks, smoke tests)
- `docs/MICROMIX_ROADMAP.md` — current direction

## Redaction

Strip API keys, passwords, tokens, and PII from the handoff before
saving.

## Example invocation

```
/handoff
```

Or with a focus area:

```
/handoff "finish the voice model selector UI"
```

The focus area tailors the "Next Steps" section to that topic.