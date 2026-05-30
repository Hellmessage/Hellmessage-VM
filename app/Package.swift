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
        // 引 HVMEncryption: CloneManager 加密 VM 分支用 EncryptedBundleIO/EncryptedConfigIO/
        // RoutingJSON. 不循环 (HVMEncryption 不引 HVMStorage).
        .target(name: "HVMStorage", dependencies: ["HVMCore", "HVMBundle", "HVMNet", "HVMEncryption"]),
        .target(name: "HVMNet",     dependencies: ["HVMCore", "HVMBundle"]),
        // HVMDisplay (VZ view) + HVMBackend (VZ backend) 已随 QEMU-only 转向移除
        // (docs/v4/QEMU_ONLY_PIVOT.md). HVMInstall 保留 (Linux/Windows ISO + UtmGuestTools
        // + VirtioWin 下载; macOS IPSW 部分已删).
        .target(name: "HVMInstall", dependencies: ["HVMCore", "HVMBundle", "HVMStorage", "HVMUtils"]),
        .target(name: "HVMIPC",     dependencies: ["HVMCore"]),

        // 视图无关的 VM 控制层 — 收口"枚举 / 启停 / 删除"逻辑 (原散落在 hvm-cli
        // ListCommand / 老 AppModel.refreshList / spawnExternalHost 三处). CLI + 新 GUI
        // store 共用同一套门面. HostLauncher (fork --host-mode-bundle) 由本 target 提供.
        // 设计稿 docs/v4/NEW_GUI_MAIN_LAYOUT.md (M1). 不依赖 HVMBackend/Display/Qemu —
        // 控制层只 fork host 子进程, 不链接后端实现.
        .target(
            name: "HVMControl",
            dependencies: ["HVMCore", "HVMBundle", "HVMEncryption", "HVMIPC", "HVMStorage", "HVMQemu"]
        ),

        // 整 VM 加密. 设计稿 docs/v3/ENCRYPTION.md v2.2.
        // SparsebundleTool / MasterKey / PasswordKDF / EncryptionKDF / EncryptedConfigIO 等.
        // 依赖 HVMBundle: EncryptedConfigIO 走 VMConfig + Yams; 不会循环 (HVMBundle 不反过来依).
        .target(
            name: "HVMEncryption",
            dependencies: [
                "HVMCore",
                "HVMBundle",
                .product(name: "Yams", package: "Yams"),
            ]
        ),

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

        // hvm-dbg ↔ HVM GUI 测试协议 (HDP-GUI). 设计稿 docs/v3/HVM_DBG_GUI_PROTOCOL.md.
        // 仅 HVM_GUI_PROBE=1 env 启用 server, release 默认 link 但不启 (体积 +几十 KB).
        .target(
            name: "HVMGuiProbe",
            // HVMDisplayQemu: ScreenshotRenderer 把 FramebufferHostView 的当前帧
            // (renderer.snapshotCGImage) 合成进截图. bitmapImageRepForCachingDisplay
            // 不抓 Metal-backed view (MTKView 用 IOSurface) → 嵌入 framebuffer 截出来
            // 是黑块. 必须从 renderer 拿 CGImage 再用 CGContext draw 到对应 rect.
            dependencies: ["HVMCore", "HVMIPC", "HVMDisplayQemu"]
        ),

        // 可执行 target
        .executableTarget(
            name: "HVM",
            dependencies: ["HVMInstall", "HVMIPC", "HVMStorage", "HVMQemu", "HVMDisplayQemu", "HVMUtils", "HVMEncryption", "HVMControl", "HVMGuiProbe"]
        ),
        .executableTarget(
            name: "hvm-cli",
            dependencies: [
                "HVMCore", "HVMBundle", "HVMStorage", "HVMNet",
                "HVMInstall", "HVMIPC", "HVMQemu", "HVMUtils",
                "HVMEncryption", "HVMControl",
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

        // 测试 target 已全部移除. CLAUDE.md 约束: 不写 XCTest. 验证走 make build + 真机 e2e
        // (hvm-cli / hvm-dbg / GUI), 不再维护 unit test 矩阵.
    ]
)
