# Tooling

## Build and test (authoritative)
- 2026-09-22: The only trustworthy verification is `xcodegen generate` then
  `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'`.
  Full suite currently 90 tests / 15 suites.

## SourceKit-LSP: root cause and fix (2026-09-22)
- Symptom: `lens_diagnostics source=lsp` reports `Cannot find type '<ModuleType>' in scope`
  for every cross-file reference (`Palette`, `LibraryItem`, `JobStatus`,
  `MicromixAPIError`, …) in **all** Swift files, including untouched ones.
- Root cause, two parts:
  1. pi-lens's built-in Swift server detects its root with
     `createRootDetector(["Package.swift"])`. This repo had no `Package.swift`,
     so the detector returned nothing and pi-lens launched `sourcekit-lsp` with
     `cwd` = the file's own directory (`reason=dispatch-root`) — never the repo
     root where `buildServer.json` lives.
  2. Xcode 27 emits a single whole-module `swiftc @FileList` invocation with no
     `-primary-file` per file, so `xcode-build-server` 1.3.0 writes `.compile`
     entries with `"files": []`. sourcekit-lsp therefore receives no per-file
     build flags.
- Fix: `MacOS/Package.swift` — a language-server-only SwiftPM manifest whose
  `.target(name: "Micromix", path: "sources")` mirrors the XcodeGen sources.
  sourcekit-lsp then uses the SwiftPM workspace and resolves the module; the
  manifest is also the root marker pi-lens looks for, so no custom server
  config is needed. Verified with a direct sourcekit-lsp probe: opening
  `MacOS/sources/Core/JobFlow.swift` at root `MacOS/` returns 0 diagnostics
  (12 before the fix).
- The manifest is for the language server only. XcodeGen/Xcode still build from
  `project.yml` / `Micromix.xcodeproj`; keep the two source lists in mind if a
  directory is ever added.
- pi-lens caches LSP roots/findings per session. After adding a root marker,
  start a new pi session (or restart the pi-lens pipeline) so it re-resolves;
  until then `lens_diagnostics` keeps replaying cached false positives.
- Do not delete `~/Library/Developer/Xcode/DerivedData/Micromix-*` while an
  editor/LSP session is live; it invalidates the running LSP's build root.
- 2026-09-22: `xcode-build-server`'s `buildServer.json` route was also tried:
  `kind: "xcode"` and `"manual"`, `.compile`, `SWIFT_ENABLE_BATCH_MODE=NO`,
  `COMPILER_INDEX_STORE_ENABLE=YES`, and a hand-made per-file
  `compile_commands.json` (`-primary-file` is rejected: "unknown argument").
  None fed sourcekit-lsp usable flags; the SwiftPM manifest is the working path.
- 2026-09-22: The `swiftlens` MCP server's `swift_lsp_diagnostics` is a stub
  (`status: not_implemented`); `swiftlens_swift_build_index` exists but was not
  needed once the manifest was in place.
