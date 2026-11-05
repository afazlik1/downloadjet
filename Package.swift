// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IDM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IDM", targets: ["MacDownloadManager"])
    ],
    targets: [
        .target(name: "DownloadCore"),
        .executableTarget(
            name: "MacDownloadManager",
            dependencies: ["DownloadCore"]
        ),
        .executableTarget(
            name: "DownloadCoreChecks",
            dependencies: ["DownloadCore"],
            path: "Tests/DownloadCoreChecks",
            exclude: ["server.py"]
        )
    ],
    swiftLanguageModes: [.v5]
)
