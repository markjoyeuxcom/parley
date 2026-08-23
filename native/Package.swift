// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ParleyNative",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "parley-native", targets: ["ParleyNative"]),
        .executable(name: "parley-core-service", targets: ["ParleyCoreService"]),
        .executable(name: "parley-native-checks", targets: ["ParleyCoreChecks"]),
        .executable(name: "parley-conformance", targets: ["ParleyConformance"]),
        .library(name: "ParleyCore", targets: ["ParleyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
    ],
    targets: [
        .target(name: "ParleyCore"),
        .executableTarget(
            name: "ParleyNative",
            dependencies: [
                "ParleyCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(name: "ParleyCoreService", dependencies: ["ParleyCore"]),
        .executableTarget(name: "ParleyCoreChecks", dependencies: ["ParleyCore"]),
        .executableTarget(name: "ParleyConformance", dependencies: ["ParleyCore"]),
    ]
)
