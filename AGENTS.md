# Repository Guidelines

## Project Structure & Module Organization

The macOS SwiftUI app lives under `MacOS/sources/`; tests are in `MacOS/Tests/`.

The local FastAPI inference sidecar lives in `services/local-inference/`; operational checks live in `scripts/`. Keep generated assets and private voice models in ignored `services/local-inference/data/`, and downloaded model caches outside Git.

## Product Scope

Micromix is a private, solo-user project and will not be published. The native macOS app is the only user-facing product. All inference runs locally on the Mac, using Apple Silicon models where supported. There is no `lts1`, remote inference, or Docker deployment dependency. Do not build a web app, public service, multi-user features, or publishing infrastructure unless explicitly requested.

## Workspace Ownership & Local Development

Perform native app, inference-engine, FastAPI, and model integration work on this Mac in this repository. The app connects to the local sidecar at `http://127.0.0.1:8902`. Network access may be needed to install dependencies and download model weights; inference must run locally. Do not restore the retired `lts1` stack or merge legacy server branches wholesale.

Inspect status, branch, and remotes, then fetch and use `git pull --ff-only` before starting work. Keep app and sidecar changes in this one GitHub repository. If histories diverge or a checkout is dirty, stop and reconcile—never force-push, reset, or copy over changes. Historical server plans are background context, not current deployment instructions; use `README.md` and `docs/MICROMIX_ROADMAP.md` for the current direction.

## Build, Test, and Development Commands

- `cd MacOS && xcodegen generate`: generate the Xcode project.
- `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'`: run native tests.
- `cd services/local-inference && uv sync`: install local sidecar dependencies.
- `cd services/local-inference && .venv/bin/python -m local_inference.main`: run the sidecar locally (when the LaunchAgent is not already running).
- `curl http://127.0.0.1:8902/v1/health` and `bash scripts/smoke-test.sh`: lightweight health and capability checks without model inference.
- See root `README.md` for optional LaunchAgent setup and manual inference checks.

## Coding Style & Naming Conventions

Use four-space indentation. Follow PEP 8 and `snake_case` in Python. In Swift, use `UpperCamelCase` types, `lowerCamelCase` members, and Swift 6 concurrency-safe patterns. Match neighboring code.

## Testing Guidelines & Tool Safety

Swift tests use `Testing` with `@Suite`, `@Test`, and `#expect`; name files `*Tests.swift`. Agents may use Xcode MCP tools, `sim-use`, and `xcodebuild` only for headless, non-interactive testing. Do not run automation that moves the mouse, sends keystrokes, takes focus, or controls the active desktop session. For heavy, visual, end-to-end, performance, or manual acceptance testing, stop and alert the user. Provide exact build/run steps and a focused checklist, then wait for their manual results. Validate backend changes locally on the Mac. A ready health endpoint does not prove app contract compatibility, model inference, or audio quality.

## Commit & Pull Request Guidelines

Use Conventional Commit subjects such as `feat(macos): ...`, `fix(api): ...`, and `docs: ...`. Keep commits narrow. PRs should explain behavior, verification, API/configuration changes, and visible UI changes. Never commit `.env`, credentials, caches, generated media, or build products.
