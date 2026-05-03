// HVMInstall/OSImageCatalog.swift
// Linux / Windows guest ISO 镜像目录 (内置 catalog).
//
// V1: hardcoded 7 个常用 arm64 发行版 ISO (Ubuntu LTS x2 / Debian / Fedora / Alpine / Rocky / openSUSE)
// 加用户自定义 URL 兜底 (custom). 后续可加运行时 fetch 动态解析 SHA256SUMS 自动刷新版本.
//
// 数据由 docs/GUEST_OS_INSTALL.md 维护 + 升级时同步到本文件; 升级时:
//   1. webfetch 各发行版 SHA256SUMS / CHECKSUM 拿新 ISO 文件名 + hash
//   2. 更新本文件 entries 数组 (URL + sha256 + version)
//   3. make build 跑通 + 实测下载 1 个验证

import Foundation

/// 发行版家族 (用于 cache 目录分类 + UI 图标)
public enum OSImageFamily: String, Sendable, Equatable, Codable, CaseIterable {
    case ubuntu
    case debian
    case fedora
    case alpine
    case rocky
    case opensuse
    case custom

    public var displayLabel: String {
        switch self {
        case .ubuntu:   return "Ubuntu"
        case .debian:   return "Debian"
        case .fedora:   return "Fedora"
        case .alpine:   return "Alpine"
        case .rocky:    return "Rocky Linux"
        case .opensuse: return "openSUSE"
        case .custom:   return "Custom"
        }
    }
}

/// 单个可下载 ISO 的元数据条目.
public struct OSImageEntry: Sendable, Equatable, Codable, Identifiable {
    /// catalog 内唯一 id (e.g. "ubuntu-24.04" / "debian-13" / "alpine-3.20")
    public let id: String
    /// UI 显示名 (e.g. "Ubuntu Server 24.04 LTS")
    public let displayName: String
    public let family: OSImageFamily
    /// 版本字符串 (e.g. "24.04.4 LTS")
    public let version: String
    /// 架构 (固定 "arm64", 留字段方便未来扩展)
    public let arch: String
    /// 远程下载 URL
    public let url: URL
    /// 期望 SHA256 (lowercase hex). nil = rolling 镜像或无校验源, 不强制校验
    public let sha256: String?
    /// 估算文件大小 (bytes); UI 提示用. 0 = 未知, 真实大小以服务器 Content-Length 为准
    public let approximateSize: Int64
    /// 一句话提示, UI 显示在 entry 描述行 (e.g. "minimal headless image")
    public let hint: String?
    /// guest OS 类型 (linux / windows). 自动下载暂只支持 linux, windows 走 custom
    public let guestOS: String

    public init(
        id: String,
        displayName: String,
        family: OSImageFamily,
        version: String,
        arch: String = "arm64",
        url: URL,
        sha256: String?,
        approximateSize: Int64,
        hint: String? = nil,
        guestOS: String = "linux"
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.version = version
        self.arch = arch
        self.url = url
        self.sha256 = sha256
        self.approximateSize = approximateSize
        self.hint = hint
        self.guestOS = guestOS
    }

    /// 缓存内本地文件名 = URL 最后一段 (含小版本号便于多版本共存)
    public var cacheFileName: String {
        url.lastPathComponent
    }
}

public enum OSImageCatalog {

    /// 内置 catalog. 数据采集自 2026-05-03, 升级流程见文件头部注释.
    /// **Windows 不在此 catalog**: Win11 ARM64 官方仅 Insider 注册 (法律灰色), Win10 ARM64
    /// 官方已无 ISO 来源. Windows 走 customDownload(url:) 兜底.
    public static let entries: [OSImageEntry] = [
        // === Ubuntu ===
        OSImageEntry(
            id: "ubuntu-24.04",
            displayName: "Ubuntu Server 24.04 LTS",
            family: .ubuntu,
            version: "24.04.4 LTS (Noble Numbat)",
            url: URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.4-live-server-arm64.iso")!,
            sha256: "9a6ce6d7e66c8abed24d24944570a495caca80b3b0007df02818e13829f27f32",
            approximateSize: 3_100_000_000,
            hint: "推荐. 长期支持, 5 年安全更新到 2029-04. live-server 装机器走文本 UI"
        ),
        OSImageEntry(
            id: "ubuntu-22.04",
            displayName: "Ubuntu Server 22.04 LTS",
            family: .ubuntu,
            version: "22.04.5 LTS (Jammy Jellyfish)",
            url: URL(string: "https://cdimage.ubuntu.com/releases/22.04/release/ubuntu-22.04.5-live-server-arm64.iso")!,
            sha256: "eafec62cfe760c30cac43f446463e628fada468c2de2f14e0e2bc27295187505",
            approximateSize: 1_700_000_000,
            hint: "上一个 LTS, 安全更新到 2027-04. 体积小适合 CI / 老 dotnet runtime"
        ),

        // === Debian ===
        OSImageEntry(
            id: "debian-13",
            displayName: "Debian 13 stable (netinst)",
            family: .debian,
            version: "13.4.0 (Trixie)",
            url: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.4.0-arm64-netinst.iso")!,
            sha256: "c31f8534597df52bd310f716d271bda30a1f58e6ff8fd9e8254eba66776c42d9",
            approximateSize: 650_000_000,
            hint: "网络安装版本, 600MB 体积. 装机过程从镜像服务器现拉包"
        ),

        // === Fedora ===
        OSImageEntry(
            id: "fedora-44",
            displayName: "Fedora Server 44 (netinst)",
            family: .fedora,
            version: "44-1.7",
            url: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Server/aarch64/iso/Fedora-Server-netinst-aarch64-44-1.7.iso")!,
            sha256: "a93ebd0322cda5a439039710b727ac1899a06e1c11876cfdf7f27c25b8262cc3",
            approximateSize: 1_200_000_000,
            hint: "Fedora Server 网络安装. 装机时实时拉包. 滚动 6 个月一版"
        ),

        // === Alpine ===
        OSImageEntry(
            id: "alpine-3.20",
            displayName: "Alpine Linux 3.20 (virt)",
            family: .alpine,
            version: "3.20.10",
            url: URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-virt-3.20.10-aarch64.iso")!,
            sha256: "12aa4b6f6e96cfff19bac09f9efa501fd404f4275d7653bb6e737cbbe280b59f",
            approximateSize: 60_000_000,
            hint: "极简, 50MB. 适合容器宿主 / minimal lab. virt 版预编译 KVM 内核"
        ),

        // === Rocky Linux ===
        OSImageEntry(
            id: "rocky-9",
            displayName: "Rocky Linux 9 (minimal)",
            family: .rocky,
            version: "9.7",
            url: URL(string: "https://download.rockylinux.org/pub/rocky/9/isos/aarch64/Rocky-9.7-aarch64-minimal.iso")!,
            sha256: "7a73b4dc3426053082d1a3fb28cc594f92133354b5ec16ccd5fd06875c35645f",
            approximateSize: 2_000_000_000,
            hint: "RHEL 9 兼容. 长期支持到 2032-05. minimal 版去掉 GUI / 多语言"
        ),

        // === openSUSE Tumbleweed ===
        // 滚动发行, 用 -Current 别名, sha256 设 nil 跳过校验 (rolling 每周更新).
        OSImageEntry(
            id: "opensuse-tumbleweed",
            displayName: "openSUSE Tumbleweed (NET)",
            family: .opensuse,
            version: "rolling",
            url: URL(string: "https://download.opensuse.org/ports/aarch64/tumbleweed/iso/openSUSE-Tumbleweed-NET-aarch64-Current.iso")!,
            sha256: nil,
            approximateSize: 450_000_000,
            hint: "滚动发行 (持续更新). 体积小, 装机时实时拉包. 校验跳过 (rolling)"
        ),
    ]

    /// 按 id 查 entry. 找不到返 nil.
    public static func find(id: String) -> OSImageEntry? {
        entries.first { $0.id == id }
    }

    /// 给定 family 列出该家族下所有 entry.
    public static func entries(for family: OSImageFamily) -> [OSImageEntry] {
        entries.filter { $0.family == family }
    }
}
