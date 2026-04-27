// HVMQemu/EFIShellAutoboot.swift
// Win11 ARM64 装机用: bootmgfw.efi 加载后会显示
//   "Press any key to boot from CD or DVD......"
// 等用户按键; 5 秒不响应就放弃当前 boot device. 这里做的是 spam Enter,
// 在 bootmgfw 出 prompt 后立即接住, 让 wpe.wim 加载, 进入 Setup.
//
// 不需要进 EFI Shell 跑 bootaa64.efi: 自家 build 的 EDK2 stable202408
// PlatformBootManagerLibLight 行为是无 NV BootOrder 时自动 boot first device,
// 所以 firmware ~5-8s 内就跳到 bootmgfw. (stable202508 改了这个行为, 落 EFI Shell;
// 我们锁 stable202408 跟 hell-vm 同源, build 出来跟 kraxel firmware 行为一致.)
//
// 触发条件 (QemuHostEntry 启动后调):
//   - guestOS == .windows
//   - bootFromDiskOnly == false (有装机 ISO 挂着, 还没装完)
//
// 装完后 (bootFromDiskOnly=true), Win Boot Manager NV 已写, EDK2 自动 boot Windows
// from disk, 不显示 "Press any key" 提示, 这里 spam 的 Enter 进 Win logon screen
// 也无害 (Windows 把多余的 Enter 当用户输入处理).

import Foundation
import HVMCore

public enum EFIShellAutoboot {

    /// 等 bootmgfw 出 "Press any key" prompt 后 spam Enter 接住. 失败 fail-soft 只 log warn.
    /// - Parameters:
    ///   - client: 已经 connect 的 QMP client.
    ///   - waitBootmgrSec: 等 EDK2 → bootmgfw 加载到 prompt 的窗口
    ///     (默认 6s; 实测 stable202408 firmware 启动到 prompt 大约 7-9s).
    public static func injectBootISO(via client: QmpClient, waitBootmgrSec: Int = 6) async {
        // 等 bootmgfw 显示 prompt. 太早 spam → 被 EDK2 BdsDxe 吞掉; 太晚 → bootmgfw 已 timeout.
        try? await Task.sleep(nanoseconds: UInt64(waitBootmgrSec) * 1_000_000_000)

        // spam Enter 持续 ~12s, 0.4s 间隔 = 30 次, 覆盖 bootmgfw "Press any key" 5s 倒计时窗口.
        // bootmgfw 看到第一个 keypress 立即开始加载 wpe.wim, 后续 Enter 被 Setup 吞掉无害.
        for _ in 0..<30 {
            try? await client.sendKey(["ret"], holdTimeMs: 50)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}
