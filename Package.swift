// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zide",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "Zide",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Zide"
        )
    ]
)
