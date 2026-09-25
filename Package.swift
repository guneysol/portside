// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Portside",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Portside", path: "Sources/Portside")
    ]
)
