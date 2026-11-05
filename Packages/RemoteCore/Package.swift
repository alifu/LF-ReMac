// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"])
    ],
    targets: [
        .target(name: "RemoteCore"),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"])
    ]
)
