// swift-tools-version: 5.9
// s1 — voice-first computer-use harness (System 1) for macOS.
// v0 scope: see -> decide -> act -> record, with a destructive-action gate
// and a JSONL audit log. No voice, no System 1/2 models yet (see README).
import PackageDescription

let package = Package(
    name: "s1",
    platforms: [
        // SCScreenshotManager (ScreenCaptureKit screenshot API) requires macOS 14+.
        .macOS(.v14)
    ],
    products: [
        .library(name: "s1", targets: ["s1"]),
        .executable(name: "s1-cli", targets: ["s1cli"]),
    ],
    targets: [
        // The harness. Portable core (gate, loop, log, preflight model, CLI)
        // plus macOS-only implementations behind `#if canImport` guards.
        .target(name: "s1", path: "Sources/s1"),
        // Thin executable: all logic lives in the library so it is testable
        // off-macOS (CI on Linux).
        .executableTarget(name: "s1cli", dependencies: ["s1"], path: "Sources/s1cli"),
        .testTarget(name: "s1Tests", dependencies: ["s1"], path: "Tests/s1Tests"),
    ]
)
