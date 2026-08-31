# Repository Guidelines

## Project Structure & Module Organization

The macOS SwiftUI app lives under `MacOS/sources/`; tests are in `MacOS/Tests/`.

`docker-compose.yml`, `services/micromix-api/`, and `scripts/` define the inference stack on `lts1`. Keep generated model data in ignored `data/`.

## Product Scope

Micromix is a private, solo-user project and will not be published. The native macOS app is the only user-facing product; `lts1` exists only for inference and backend APIs that power it. Do not build a web app, public service, multi-user features, or publishing infrastructure unless explicitly requested.

## Workspace Ownership & Server Deployment

Use this Mac for frontend and app-level work. Perform all inference-engine, FastAPI, and Docker Compose work on the server:

```bash
ssh lts1
cd ~/apps/micromix
```

Both checkouts use one GitHub repository; never create a separate backend repository. Inspect status, branch, and remotes, then fetch and use `git pull --ff-only`. Commit and push where changes are made, then pull into the other checkout before related work or deployment. If histories diverge or a checkout is dirty, stop and reconcile—never force-push, reset, or copy over changes.

## Build, Test, and Development Commands

- `cd MacOS && xcodegen generate`: generate the Xcode project.
- `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'`: run native tests.
- On `lts1`, `docker compose up -d --build`: deploy inference services.
- On `lts1`, `docker compose logs -f muscriptor-api`: follow wrapper logs.
- On `lts1`, use `curl http://localhost:8902/v1/health` and scripts under `scripts/` for checks.

## Coding Style & Naming Conventions

Use four-space indentation. Follow PEP 8 and `snake_case` in Python. In Swift, use `UpperCamelCase` types, `lowerCamelCase` members, and Swift 6 concurrency-safe patterns. Match neighboring code.

## Testing Guidelines & Tool Safety

Swift tests use `Testing` with `@Suite`, `@Test`, and `#expect`; name files `*Tests.swift`. Agents may use Xcode MCP tools, `sim-use`, and `xcodebuild` only for headless, non-interactive testing. Do not run automation that moves the mouse, sends keystrokes, takes focus, or controls the active desktop session. For heavy, visual, end-to-end, performance, or manual acceptance testing, stop and alert the user. Provide exact build/run steps and a focused checklist, then wait for their manual results. Validate backend changes on `lts1`.

## Commit & Pull Request Guidelines

Use Conventional Commit subjects such as `feat(macos): ...`, `fix(api): ...`, and `docs: ...`. Keep commits narrow. PRs should explain behavior, verification, API/configuration changes, and visible UI changes. Never commit `.env`, credentials, caches, generated media, or build products.
