// HVMQemu/EFIShellAutoboot.swift
// Win11 ARM64 装机用: EDK2 firmware 启动后落到 EFI Shell, Swift 端通过 QMP send-key
// 自动注入 `fs0:` + `\efi\boot\bootaa64.efi`, 然后 spam Enter 接 bootmgfw 的
// "Press any key to boot from CD or DVD" 5 秒 prompt.
//
// 触发条件 (QemuHostEntry 启动后调):
//   - guestOS == .windows
//   - bootFromDiskOnly == false (有装机 ISO 挂着, 还没装完)
//
// 装完后 (bootFromDiskOnly=true), Win Boot Manager NV 已写, EDK2 自动 boot Windows
// from disk, 不需要这套注入.

import Foundation
import HVMCore

public enum EFIShellAutoboot {

    /// 等 EDK2 落 EFI Shell 后注入 boot 命令链. 失败 (timeout) fail-soft 只 log warn.
    /// - Parameters:
    ///   - client: 已经 connect 的 QMP client.
    ///   - waitShellSec: 等 EDK2 落 EFI Shell 的窗口 (默认 30s; 实测 stable202408 firmware
    ///     从启动到 Shell prompt 大约 18-22s).
    public static func injectBootISO(via client: QmpClient, waitShellSec: Int = 30) async {
        // EDK2 启动 → TianoCore splash → Press ESC to skip startup.nsh → EFI Shell.
        // 等够时间让 firmware 走到 Shell prompt; 再过早 send-key 会被 BdsDxe 吞掉.
        try? await Task.sleep(nanoseconds: UInt64(waitShellSec) * 1_000_000_000)

        do {
            // 1. ESC 跳过 startup.nsh 倒计时 (即使 nsh 不存在, 不按 ESC 默认会等 1s)
            try await client.sendKey(["esc"], holdTimeMs: 100)
            try await Task.sleep(nanoseconds: 500_000_000)

            // 2. fs0: → 切到 Win11 ISO 的文件系统映射
            //    qcode "shift" + "semicolon" 组合等价于按 ":"
            for k in ["f", "s", "0"] {
                try await client.sendKey([k], holdTimeMs: 50)
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            try await client.sendKey(["shift", "semicolon"], holdTimeMs: 100)
            try await client.sendKey(["ret"], holdTimeMs: 100)
            try await Task.sleep(nanoseconds: 500_000_000)

            // 3. \efi\boot\bootaa64.efi → 跑 Windows EFI bootloader
            //    Win11 ISO 上路径 (case-insensitive, 但保险用小写)
            let cmd: [String] = [
                "e", "f", "i",
                "backslash",
                "b", "o", "o", "t",
                "backslash",
                "b", "o", "o", "t", "a", "a", "6", "4",
                "dot",
                "e", "f", "i",
            ]
            for k in cmd {
                try await client.sendKey([k], holdTimeMs: 50)
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            try await client.sendKey(["ret"], holdTimeMs: 100)

            // 4. spam Enter 接 bootmgfw "Press any key to boot from CD or DVD" 5 秒 prompt.
            //    bootmgfw 加载 ~1-2s 内就显示 prompt; 我们立即开始 spam, 0.3s 间隔, 共 30 次 = 9s,
            //    覆盖 bootmgfw 的 5s 倒计时窗口. 多余的 Enter 在 wpe.wim 启动后会被 Setup 吞掉, 无害.
            for _ in 0..<30 {
                try? await client.sendKey(["ret"], holdTimeMs: 50)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        } catch {
            let msg = error.localizedDescription
            HVMLog.logger("qemu.efishell").warning(
                "EFIShellAutoboot 注入失败: \(msg, privacy: .public)"
            )
        }
    }
}
