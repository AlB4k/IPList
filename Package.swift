// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPList",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IPList", targets: ["IPList"])
    ],
    targets: [
        .executableTarget(name: "IPList")
    ]
)
