// swift-tools-version:6.0
// Vendored SwiftTerm 1.20.0 (MIT, see LICENSE) without the optional Metal renderer's
// shader resource, so it builds without Xcode's separately-downloaded Metal toolchain.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Documentation.docc"],
            plugins: [.plugin(name: "SwiftTermBuildInfoPlugin")]
        ),
        .executableTarget(name: "SwiftTermBuildInfoGenerator", path: "Sources/SwiftTermBuildInfoGenerator"),
        .plugin(name: "SwiftTermBuildInfoPlugin", capability: .buildTool(), dependencies: ["SwiftTermBuildInfoGenerator"]),
    ],
    swiftLanguageModes: [.v5]
)
