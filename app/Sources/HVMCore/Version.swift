// HVMCore/Version.swift
// 版本号常量, GUI / CLI / dbg 共用
// 真实版本号在 .app Info.plist 由 git describe 注入, 这里仅作源码侧默认

public enum HVMVersion {
    /// 开发期默认版本字符串. Release 包以 Info.plist 的 CFBundleShortVersionString 为准
    public static let marketing = "0.0.1"
    public static let milestone = "M0 skeleton"

    /// 组合字符串, 用于 CLI --version 与 GUI 占位
    public static var displayString: String {
        "HVM v\(marketing) — \(milestone)"
    }
}
