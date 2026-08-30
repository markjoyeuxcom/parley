// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ParleyNative",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "parley-native", targets: ["ParleyNative"]),
        .executable(name: "parley-native-checks", targets: ["ParleyCoreChecks"]),
        .executable(name: "parley-native-soak", targets: ["ParleySoak"]),
        .library(name: "ParleyCore", targets: ["ParleyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.4.7"),
    ],
    targets: [
        .target(name: "ParleyCore"),
        .executableTarget(
            name: "ParleyNative",
            dependencies: [
                "ParleyCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),
        .executableTarget(
            name: "ParleyCoreChecks",
            dependencies: [
                "ParleyCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),
        .executableTarget(
            name: "ParleySoak",
            dependencies: [
                "ParleyCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),
    ]
)
