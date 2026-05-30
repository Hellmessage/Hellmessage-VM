// HVMTheme.swift — 新 GUI 顶层 namespace (.color / .font / .space / .radius / .border / .motion 子 namespace).
//
// enum HVMTheme {} 作 namespace 跨文件 extension 扩, 避开老 GUI 顶层 HVMColor 撞名 (同 HVM target 编译).
// 防漂移护栏: scripts/check-gui-tokens.sh 扫整个 GUI/ 拦硬编码颜色/字号/padding.


enum HVMTheme {}

