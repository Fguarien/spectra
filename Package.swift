// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spectra",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.0")
    ],
    targets: [
        .executableTarget(
            name: "Spectra",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/Spectra",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpectraTests",
            dependencies: ["Spectra"],
            path: "Tests/SpectraTests"
        ),
        .testTarget(
            name: "SpectraUITests",
            dependencies: ["Spectra"],
            path: "Tests/SpectraUITests"
        )
    ]
)
