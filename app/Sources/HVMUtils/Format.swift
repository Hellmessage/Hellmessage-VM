// HVMUtils/Format.swift
// 跨模块共用的数字 → 人类可读字符串格式化.
// 收纳前散点: hvm-cli IpswCommand / UI IpswFetchDialog / UI VirtioWinFetchDialog /
// UI UtmGuestToolsFetchDialog (同一份 formatBytes / formatRate / formatETA 复制粘贴 4 份).
//
// 单位: 二进制 (KiB / MiB / GiB), 与 IPSW / ISO / virtio-win 等下载场景的 disk image
// 大小语义一致.
//
// padded 参数: true 时返回固定宽度字符串 (CLI \r 刷新时对齐用); false 时紧凑输出 (UI 用).

import Foundation

public enum Format {

    // MARK: - 字节大小

    /// bytes → "1.23 GiB" / "456.7 MiB" / "789 B"
    /// - Parameter padded: true 时按 CLI 对齐宽度输出 ("%6.2f GiB"); false 时紧凑 ("%.2f GiB")
    public static func bytes(_ n: Int64, padded: Bool = false) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        let v = Double(n)
        if v >= gb {
            return String(format: padded ? "%6.2f GiB" : "%.2f GiB", v / gb)
        }
        if v >= mb {
            return String(format: padded ? "%6.1f MiB" : "%.1f MiB", v / mb)
        }
        if v >= kb {
            return String(format: padded ? "%6.1f KiB" : "%.1f KiB", v / kb)
        }
        return padded ? String(format: "%6d B  ", n) : "\(n) B"
    }

    // MARK: - 速率 (bytes/sec)

    /// bytes/sec → "12.4 MiB/s" / "789 B/s"
    public static func rate(_ bps: Double, padded: Bool = false) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024
        if bps >= gb {
            return String(format: padded ? "%6.2f GiB/s" : "%.2f GiB/s", bps / gb)
        }
        if bps >= mb {
            return String(format: padded ? "%6.2f MiB/s" : "%.1f MiB/s", bps / mb)
        }
        if bps >= kb {
            return String(format: padded ? "%6.1f KiB/s" : "%.1f KiB/s", bps / kb)
        }
        return padded ? String(format: "%6.0f B/s  ", bps) : String(format: "%.0f B/s", bps)
    }

    // MARK: - ETA (剩余秒数)

    /// seconds → "1h12m" / "6 min" / "12s" / "--"
    public static func eta(_ seconds: Double, padded: Bool = false) -> String {
        if !seconds.isFinite || seconds < 0 {
            return padded ? "  --  " : "--"
        }
        let s = Int(seconds)
        if s >= 3600 {
            let h = s / 3600
            let m = (s % 3600) / 60
            return String(format: padded ? "%2dh%02dm" : "%dh%02dm", h, m)
        }
        if s >= 60 {
            let m = s / 60
            return padded ? String(format: "%4d min", m) : "\(m) min"
        }
        return padded ? String(format: "%5d s", s) : "\(s) s"
    }
}
