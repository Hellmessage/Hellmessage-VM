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
        // Yams: YAML 1.1 解析器 (libyaml C 包装). CLAUDE.md 唯一允许的 YAML dep.
        // BundleIO 用它读写 <bundle>/config.yaml. SwiftPM 默认静态链接, 自动嵌入
        // HVM/hvm-cli/hvm-dbg 二进制本体, 空白机器无需额外安装.
        .package(
            url: "https://github.com/jpsim/Yams",
            from: "5.1.0"
        ),
    ],
    targets: [
        // 基础库, 无下游依赖
        .target(name: "HVMCore"),

        // 公共工具 (formatBytes / sha256Hex / 后续 ResumableDownloader 等跨模块共用 helper).
        // 仅依赖 HVMCore (拿 HVMLog), 不引业务语义.
        .target(name: "HVMUtils", dependencies: ["HVMCore"]),

        // 功能模块
        .target(
            name: "HVMBundle",
            dependencies: [
                "HVMCore",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        // HVMStorage 依赖 HVMNet 仅用于 CloneManager 重生 NIC MAC (走 MACAddressGenerator),
        // 与 BundleIO/DiskFactory 平行. 拒绝在 CloneManager 里复制一份 MAC 生成逻辑.
        .target(name: "HVMStorage", dependencies: ["HVMCore", "HVMBundle", "HVMNet"]),
        .target(name: "HVMNet",     dependencies: ["HVMCore", "HVMBundle"]),
        .target(name: "HVMDisplay", dependencies: ["HVMCore", "HVMBundle", "HVMUtils"]),
        .target(
            name: "HVMBackend",
            dependencies: ["HVMCore", "HVMBundle", "HVMStorage", "HVMNet", "HVMDisplay"]
        ),
        .target(name: "HVMInstall", dependencies: ["HVMCore", "HVMBundle", "HVMStorage", "HVMBackend", "HVMUtils"]),
        .target(name: "HVMIPC",     dependencies: ["HVMCore"]),

        // QEMU 后端: 进程编排 + argv 构造 + QMP 客户端 (与 HVMBackend 平行, 不依赖 VZ)
        .target(name: "HVMQemu",    dependencies: ["HVMCore", "HVMBundle", "HVMUtils"]),

        // SCM_RIGHTS fd 接收 helper (POSIX recvmsg + cmsg). 单独 C target 因
        // Swift 不能直接调 CMSG_FIRSTHDR / CMSG_DATA / CMSG_LEN 等宏.
        // 仅给 HVMDisplayQemu 用 (接 HDP SURFACE_NEW 携带的 shm fd).
        .target(name: "HVMScmRecv"),

        // QEMU iosurface 显示嵌入: HDP v1.0.0 协议 (docs/QEMU_DISPLAY_PROTOCOL.md)
        // socket 客户端 + Metal 零拷贝渲染 + QMP 输入转发. 配套 patch 0002.
        .target(
            name: "HVMDisplayQemu",
            dependencies: ["HVMCore", "HVMBundle", "HVMQemu", "HVMScmRecv"]
        ),

        // 可执行 target
        .executableTarget(
            name: "HVM",
            dependencies: ["HVMBackend", "HVMInstall", "HVMIPC", "HVMDisplay", "HVMStorage", "HVMQemu", "HVMDisplayQemu", "HVMUtils"]
        ),
        .executableTarget(
            name: "hvm-cli",
            dependencies: [
                "HVMCore", "HVMBundle", "HVMStorage", "HVMNet",
                "HVMBackend", "HVMInstall", "HVMIPC", "HVMQemu", "HVMUtils",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "hvm-dbg",
            dependencies: [
                "HVMCore", "HVMBundle", "HVMIPC", "HVMQemu", "HVMInstall", "HVMUtils",
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
            name: "HVMDisplayTests",
            dependencies: ["HVMDisplay", "HVMBundle", "HVMCore"]
        ),
        .testTarget(
            name: "HVMDisplayQemuTests",
            dependencies: ["HVMDisplayQemu", "HVMCore"]
        ),
        .testTarget(
            name: "HVMQemuTests",
            dependencies: ["HVMQemu", "HVMBundle", "HVMCore"]
        ),
        .testTarget(
            name: "HVMScmRecvTests",
            dependencies: ["HVMScmRecv"]
        ),
    ]
)
