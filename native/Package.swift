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
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.5.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "ParleyCore"),
        .executableTarget(
            name: "ParleyNative",
            dependencies: [
                "ParleyCore",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Sparkle", package: "Sparkle"),
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
