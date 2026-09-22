// swift-tools-version: 6.0
// Language-server manifest. The app is built by XcodeGen from `project.yml`;
// this manifest exists so sourcekit-lsp can resolve the Micromix module
// (cross-file symbols) from the same `sources/` tree.
import PackageDescription

let package = Package(
    name: "Micromix",
    targets: [
        .target(
            name: "Micromix",
            path: "sources"
        )
    ]
)
