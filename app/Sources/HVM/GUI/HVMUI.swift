// HVMUI.swift — 新 GUI 组件顶层 namespace.
//
// 各组件按 extension HVMUI 加 nested struct, 一组件一文件 (HVMUIButton.swift / 等).
// 用 namespace 而非顶层 HVMButton: 避开老 GUI (UI/Style/**) 同名顶层组件撞名, 跟 HVMTheme 模式一致,
// 跟 SwiftUI 自家 Button / TextField 区分清楚 (HVMUI.Button = 新 GUI 通路).


enum HVMUI {}

