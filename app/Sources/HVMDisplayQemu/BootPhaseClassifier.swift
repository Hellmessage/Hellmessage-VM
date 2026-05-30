// HVMDisplay/BootPhaseClassifier.swift
// 纯函数: OCR 文本 + guestOS → boot 阶段分类 (bios / boot-logo / ready-tty / ready-gui / unknown).
//
// 算法: 与 hvm-dbg dbg.boot_progress 文档对齐 (docs/DEBUG_PROBE.md).
// VZ DbgOps + QEMU QemuHostState 都走此 helper, 行为一致.
//
// 上层调用方负责截屏 + OCR; 把结果传进 classify 即可拿到 (phase, confidence).
// 不依赖 IPC payload 类型 (HVMDisplay 不引 HVMIPC), 让调用方自己组装响应.

import Foundation
import HVMBundle

public enum BootPhaseClassifier {

    /// 启动阶段 + 命中置信度. confidence ∈ [0, 1], 给客户端粗判用 (≥0.7 较强信号).
    public struct Classification: Sendable, Equatable {
        public let phase: String     // "bios" / "boot-logo" / "ready-tty" / "ready-gui" / "unknown"
        public let confidence: Float

        public init(phase: String, confidence: Float) {
            self.phase = phase
            self.confidence = confidence
        }
    }

    // MARK: - 关键字常量 (与上游 docs 对齐, 改动需同步 docs/DEBUG_PROBE.md)

    /// 字符行命中 = ready-tty (登录提示符). 全 lowercase 比对.
    public static let ttyKeywords: [String] = [
        "login:", "localhost login", "raspberrypi login",
    ]

    /// guestOS 对应的 GUI 登录 / 桌面元素关键字. 全 lowercase, 任一命中 = ready-gui.
    public static func guiKeywords(for guestOS: GuestOSType) -> [String] {
        switch guestOS {
        case .macOS:
            return ["sign in", "other", "user name", "用户名", "apple", "finder"]
        case .linux:
            return ["username", "password", "sign in", "log in", "用户名", "密码"]
        case .windows:
            return ["sign in", "username", "password", "user", "administrator",
                    "windows", "登录", "用户名", "密码"]
        }
    }

    // MARK: - 公开 API

    /// 已有 OCR 结果时直接分类 (不抓屏 / 不 OCR; 这俩由调用方做完).
    /// items 空 → boot-logo (有帧但 OCR 没找到任何文本).
    public static func classify(items: [OCREngine.TextItem], guestOS: GuestOSType) -> Classification {
        if items.isEmpty {
            return Classification(phase: "boot-logo", confidence: 0.6)
        }
        let lowered = items.map { $0.text.lowercased() }
        let joined = lowered.joined(separator: " ")

        if ttyKeywords.contains(where: { joined.contains($0) }) {
            return Classification(phase: "ready-tty", confidence: 0.9)
        }
        let gui = guiKeywords(for: guestOS)
        if gui.contains(where: { kw in lowered.contains(where: { $0.contains(kw) }) }) {
            return Classification(phase: "ready-gui", confidence: 0.8)
        }
        return Classification(phase: "unknown", confidence: 0.4)
    }
}
