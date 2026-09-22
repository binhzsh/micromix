# Tooling

## Build and test (authoritative)
- 2026-09-22: The only trustworthy verification is `xcodegen generate` then
  `cd MacOS && xcodebuild test -project Micromix.xcodeproj -scheme Micromix -destination 'platform=macOS'`.
  Full suite currently 90 tests / 15 suites.

## SourceKit-LSP is broken for this workspace
- 2026-09-22: `lens_diagnostics source=lsp` reports `Cannot find type '<ModuleType>' in scope`
  for every cross-file reference (e.g. `Palette`, `LibraryItem`, `JobStatus`,
  `MicromixAPIError`) in **all** files, including files untouched by the change
  under review. Treat these as false positives.
- 2026-09-22: Root cause is the generated `xcode-build-server` compile database:
  `.compile` contains whole-module `fileLists` entries with `"files": []`, so
  sourcekit-lsp cannot map per-file build flags. Reproduced under Xcode 27.0
  (27A5252f) with `xcode-build-server` 1.3.0, including with
  `SWIFT_ENABLE_BATCH_MODE=NO` and `COMPILER_INDEX_STORE_ENABLE=YES`.
- 2026-09-22: Tried and did not fix it: regenerating `buildServer.json`
  (`xcode-build-server config`), a clean indexed rebuild, `xcode-build-server parse`,
  and killing/restarting the `sourcekit-lsp` processes.
- 2026-09-22: Do not delete `~/Library/Developer/Xcode/DerivedData/Micromix-*` while
  an editor/LSP session is live; it invalidates the running LSP's build root.
- 2026-09-22: `.compile` and `buildServer.json` are machine-generated and gitignored.
