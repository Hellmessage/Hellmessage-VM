// swift-tools-version: 6.0
// HVM 主构建 manifest
// 约束: 仅依赖官方 framework + swift-argument-parser, 目标 macOS 14+

import PackageDescription

let package = Package(
    name: "HVM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HVM",     targets: ["HVM"]),
        .executable(name: "hvm-cli", targets: ["hvm-cli"]),
        .executable(name: "hvm-dbg", targets: ["hvm-dbg"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
    ],
    targets: [
        // 基础库, 无下游依赖
        .target(name: "HVMCore"),

        // 功能模块
        .target(name: "HVMBundle",  dependencies: ["HVMCore"]),
        .target(name: "HVMStorage", dependencies: ["HVMCore"]),
        .target(name: "HVMNet",     dependencies: ["HVMCore", "HVMBundle"]),
        .target(name: "HVMDisplay", dependencies: ["HVMCore", "HVMBundle"]),
        .target(
            name: "HVMBackend",
            dependencies: ["HVMCore", "HVMBundle", "HVMStorage", "HVMNet", "HVMDisplay"]
        ),
        .target(name: "HVMInstall", dependencies: ["HVMBackend"]),
        .target(name: "HVMIPC",     dependencies: ["HVMCore"]),

        // 可执行 target
        .executableTarget(
            name: "HVM",
            dependencies: ["HVMBackend", "HVMInstall", "HVMIPC", "HVMDisplay"]
        ),
        .executableTarget(
            name: "hvm-cli",
            dependencies: [
                "HVMCore", "HVMBundle", "HVMStorage", "HVMNet",
                "HVMBackend", "HVMInstall", "HVMIPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "hvm-dbg",
            dependencies: [
                "HVMIPC", "HVMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // 测试 (M0 只放 HVMCore 烟雾测试占位)
        .testTarget(name: "HVMCoreTests", dependencies: ["HVMCore"]),
    ]
)
