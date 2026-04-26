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
        .target(name: "HVMStorage", dependencies: ["HVMCore", "HVMBundle"]),
        .target(name: "HVMNet",     dependencies: ["HVMCore", "HVMBundle"]),
        .target(name: "HVMDisplay", dependencies: ["HVMCore", "HVMBundle"]),
        .target(
            name: "HVMBackend",
            dependencies: ["HVMCore", "HVMBundle", "HVMStorage", "HVMNet", "HVMDisplay"]
        ),
        .target(name: "HVMInstall", dependencies: ["HVMCore", "HVMBundle", "HVMStorage", "HVMBackend"]),
        .target(name: "HVMIPC",     dependencies: ["HVMCore"]),

        // QEMU 后端: 进程编排 + argv 构造 + QMP 客户端 (与 HVMBackend 平行, 不依赖 VZ)
        .target(name: "HVMQemu",    dependencies: ["HVMCore", "HVMBundle"]),

        // 可执行 target
        .executableTarget(
            name: "HVM",
            dependencies: ["HVMBackend", "HVMInstall", "HVMIPC", "HVMDisplay", "HVMStorage", "HVMQemu"]
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
                "HVMCore", "HVMBundle", "HVMIPC", "HVMQemu", "HVMInstall",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // 单元测试 (XCTest), 只覆盖纯逻辑模块, VZ 相关不测 (需要 macOS host + 资源)
        .testTarget(
            name: "HVMCoreTests",
            dependencies: ["HVMCore"]
        ),
        .testTarget(
            name: "HVMBundleTests",
            dependencies: ["HVMBundle", "HVMCore"]
        ),
        .testTarget(
            name: "HVMNetTests",
            dependencies: ["HVMNet", "HVMCore"]
        ),
        .testTarget(
            name: "HVMStorageTests",
            dependencies: ["HVMStorage", "HVMBundle", "HVMCore"]
        ),
        .testTarget(
            name: "HVMInstallTests",
            dependencies: ["HVMInstall", "HVMCore"]
        ),
        .testTarget(
            name: "HVMIPCTests",
            dependencies: ["HVMIPC", "HVMCore"]
        ),
        .testTarget(
            name: "HVMQemuTests",
            dependencies: ["HVMQemu", "HVMBundle", "HVMCore"]
        ),
    ]
)
