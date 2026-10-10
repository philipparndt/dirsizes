// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dirsizes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DirScanner", targets: ["DirScanner"]),
        .executable(name: "dirsizes", targets: ["dirsizes"]),
        .executable(name: "DirSizesApp", targets: ["DirSizesApp"]),
    ],
    targets: [
        .target(name: "DirScanner"),
        .executableTarget(name: "dirsizes", dependencies: ["DirScanner"]),
        .executableTarget(name: "DirSizesApp", dependencies: ["DirScanner"]),
    ],
    swiftLanguageModes: [.v5]
)
