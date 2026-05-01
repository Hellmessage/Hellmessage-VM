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
//   - NVRAM 中没写过 "Windows Boot Manager" 字串 (没装过 Win)
//
// 第三个条件是关键防误射: 即便 user 还没把 bootFromDiskOnly 切到 true, 只要 Win
// 已装完, NVRAM 里有 BootXXXX 指向 "Windows Boot Manager", EDK2 会直接 boot Windows
// 进 OOBE / logon, 不出现 "Press any key" 提示. 这时 spam 的 Enter 会命中 OOBE
// 当前焦点元素反复 click (例如焦点在 "支持" 链接, user 看到一直被点击).

import Foundation
import HVMCore

public enum EFIShellAutoboot {

    /// 等 bootmgfw 出 "Press any key" prompt 后 spam Enter 接住. 失败 fail-soft 只 log warn.
    /// - Parameters:
    ///   - client: 已经 connect 的 QMP client.
    ///   - nvramURL: 该 VM 的 efi-vars.fd 路径. 已含 "Windows Boot Manager" 时直接
    ///     return, 不 spam (EDK2 会从硬盘直 boot Windows, 没 prompt 可接).
    ///   - waitBootmgrSec: 等 EDK2 → bootmgfw 加载到 prompt 的窗口
    ///     (默认 6s; 实测 stable202408 firmware 启动到 prompt 大约 7-9s).
    public static func injectBootISO(
        via client: QmpClient,
        nvramURL: URL,
        waitBootmgrSec: Int = 6
    ) async {
        // 装机后 NVRAM 写过 Windows Boot Manager → 跳过 spam, 让 user 自然进 OOBE.
        if isWindowsBootManagerInstalled(nvramURL: nvramURL) {
            return
        }

        // 等 bootmgfw 显示 prompt. 太早 spam → 被 EDK2 BdsDxe 吞掉; 太晚 → bootmgfw 已 timeout.
        try? await Task.sleep(nanoseconds: UInt64(waitBootmgrSec) * 1_000_000_000)

        // spam Enter 持续 ~2s, 0.4s 间隔 = 5 次. bootmgfw 看到第一个 keypress 就立即
        // 加载 wpe.wim, 5 次足以覆盖 wait window 内的 race; 不要 spam 太多, 避免万一
        // NVRAM 探测漏判 (例如老 Windows 版本字串编码不同) 时 Enter 砸到 OOBE 导致
        // user 看到 "支持" / "下一步" 焦点元素被反复 click. 漏接的 race 风险低 + 后果小:
        // user 手动按 Enter 一次能补救 (bootmgfw "Press any key" prompt 是显式的).
        for _ in 0..<5 {
            try? await client.sendKey(["ret"], holdTimeMs: 50)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// 检测 efi-vars.fd 是否已写过 Windows Boot Manager. 装好 Win 后, bootmgr 会在
    /// EFI BootXXXX variable 写 "Windows Boot Manager" UTF-16LE 字串 + Windows 启动器
    /// 路径; 装机前模板 NVRAM (share/qemu/edk2-aarch64-vars.fd) 不含此串.
    /// 用 mmap (.alwaysMapped) 避免一次性 64MB 读到 RAM, lazy page 实测扫描 < 50ms.
    /// 文件读不到 / decode 失败一律 false (保守, 等价 "可能没装", 走 spam 路径).
    static func isWindowsBootManagerInstalled(nvramURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: nvramURL, options: .alwaysMapped) else {
            return false
        }
        guard let pattern = "Windows Boot Manager".data(using: .utf16LittleEndian) else {
            return false
        }
        return data.range(of: pattern) != nil
    }
}
