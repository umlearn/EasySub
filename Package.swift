// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasySub",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EasySubCore", targets: ["EasySubCore"])],
    targets: [
        .target(name: "EasySubCore"),
        .testTarget(name: "EasySubCoreTests", dependencies: ["EasySubCore"])
    ]
)
