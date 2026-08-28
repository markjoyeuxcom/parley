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
        .executable(name: "parley-native-soak", targets: ["ParleySoak"]),
        .library(name: "ParleyCore", targets: ["ParleyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0"),
    ],
    targets: [
        .target(name: "ParleyCore"),
        .target(
            name: "ParleyTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "ParleyNative",
            dependencies: [
                "ParleyCore",
                "ParleyTerminal",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(name: "ParleyCoreService", dependencies: ["ParleyCore"]),
        .executableTarget(
            name: "ParleyCoreChecks",
            dependencies: [
                "ParleyCore",
                "ParleyTerminal",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(name: "ParleyConformance", dependencies: ["ParleyCore"]),
        .executableTarget(
            name: "ParleySoak",
            dependencies: [
                "ParleyCore",
                "ParleyTerminal",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)
