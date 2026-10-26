// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DocOttoDiagnostics",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "DocOttoDiagnostics", targets: ["DocOttoDiagnostics"])],
    targets: [
        .target(name: "DocOttoDiagnostics"),
        .testTarget(name: "DocOttoDiagnosticsTests", dependencies: ["DocOttoDiagnostics"])
    ]
)
