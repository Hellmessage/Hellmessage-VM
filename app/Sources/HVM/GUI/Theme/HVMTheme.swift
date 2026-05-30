// HVMTheme.swift — 新 GUI 顶层 namespace
//
// 业务侧用法 (统一一种):
//   HVMTheme.color.bgBase
//   HVMTheme.font.md
//   HVMTheme.space.lg
//   HVMTheme.radius.md
//   HVMTheme.border.hairline
//   HVMTheme.motion.easeOut
//
// 用 enum HVMTheme {} 作 namespace, 跨文件 extension 加 .color / .font / ...
// 子 namespace. 避免跟老 GUI 顶层 `public enum HVMColor` (UI/Style/Theme.swift)
// 撞名 — 老 GUI 跟新 GUI 在同一 HVM target 编译.
//
// 防漂移护栏 (PR-L1): scripts/check-gui-tokens.sh 扫整个 GUI/ 拦
// Color(red: / Color(hex: / Font.system(size: / padding(数字) 硬编码.


enum HVMTheme {}

