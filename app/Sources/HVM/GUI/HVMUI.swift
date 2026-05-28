// HVMUI.swift — 新 GUI 组件顶层 namespace
//
// 业务侧用法 (统一风格):
//   HVMUI.Button("保存", variant: .primary) { save() }
//   HVMUI.TextField("名称", text: $name)
//   HVMUI.SecureField("密码", text: $pwd)
//   HVMUI.Select("引擎", selection: $engine, options: ...)
//   HVMUI.Section("基本信息") { ... }
//
// 为什么用 namespace 而不是顶层 HVMButton / HVMTextField:
//   1. 老 GUI (UI/Style/**) 用了 HVMTextField / HVMToggle / HVMModal / HVMCard /
//      HVMPopupPanel 等顶层名, 同 HVM target 编译会撞名
//   2. 跟 HVMTheme.color / HVMTheme.font namespace 模式一致
//   3. 跟 SwiftUI 自家 Button / TextField / SecureField 区分清楚 — 业务侧
//      看到 HVMUI.Button 立刻知道走新 GUI 通路
//
// 各组件按维度独立文件 (HVMUIButton.swift / HVMUITextField.swift / 等), 通过
// extension HVMUI 加 nested struct, 实现"一组件一文件"模块化.

#if NEW_GUI

enum HVMUI {}

#endif
