// HVMModal.swift
// 统一中央 modal 容器. 所有 dialog (Confirm / Error / CreateVM / EditConfig /
// DiskAdd / DiskResize / SnapshotCreate / Install / IpswFetch / VirtioWinFetch /
// IpswCatalogPicker) 都套这个壳.
//
// 结构: 蒙底 (黑 65%) + 居中卡片 [顶栏(标题+X) | content | 底栏(按钮区)]
//
// 严格按 CLAUDE.md 弹窗约束:
//   - 只能通过右上角 X 关闭 (= dismiss)
//   - 禁止点击遮罩关闭 (蒙底 .allowsHitTesting(false))
//   - 禁止 Esc 关闭 (不绑 Esc)
//   - 禁止 NSAlert / SwiftUI .alert()
// 装机 / 下载这类不可中断流程, 用 closeAction = nil 隐藏 X 按钮.
//
// 用法:
//   HVMModal(title: "Create VM", width: 520, closeAction: { dismiss() }) {
//       formContent
//   } footer: {
//       HVMModalFooter {
//           Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle())
//           Button("Create") { submit() }.buttonStyle(PrimaryButtonStyle())
//       }
//   }
//
// 强制约束 (CLAUDE.md): 业务代码禁止再自己拼 ZStack(蒙底 + 居中卡片).

import SwiftUI

public struct HVMModal<Body: View, Footer: View>: View {
    private let title: String
    private let icon: ModalIcon
    private let width: CGFloat
    private let height: CGFloat?
    /// nil 表示不显示 X 按钮 (装机 / 下载等不可中断流程)
    private let closeAction: (() -> Void)?
    private let bodyContent: () -> Body
    private let footerContent: (() -> Footer)?

    public enum ModalIcon {
        case none
        case info
        case warning
        case error
    }

    public init(
        title: String,
        icon: ModalIcon = .none,
        width: CGFloat = 480,
        height: CGFloat? = nil,
        closeAction: (() -> Void)?,
        @ViewBuilder body: @escaping () -> Body,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.icon = icon
        self.width = width
        self.height = height
        self.closeAction = closeAction
        self.bodyContent = body
        self.footerContent = footer
    }

    public var body: some View {
        ZStack {
            // 蒙底, 不响应点击
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                Divider().background(HVMColor.border)
                bodyContent()
                    .padding(HVMSpace.lg)
                if let footerContent {
                    Divider().background(HVMColor.border)
                    footerContent()
                        .padding(.horizontal, HVMSpace.lg)
                        .padding(.vertical, HVMSpace.md)
                }
            }
            .frame(width: width)
            .frame(height: height)
            .background(HVMColor.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous)
                    .stroke(HVMColor.borderStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HVMRadius.lg, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 8)
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: HVMSpace.sm) {
            iconView
            Text(title)
                .font(HVMFont.heading)
                .foregroundStyle(HVMColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let closeAction {
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())
                .help("关闭 (Cmd+W)")
                .keyboardShortcut("w", modifiers: [.command])
            }
        }
        .padding(.horizontal, HVMSpace.lg)
        .padding(.vertical, HVMSpace.md)
        .frame(height: 48)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .none:
            EmptyView()
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(HVMColor.accent)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(HVMColor.statusPaused)
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 13))
                .foregroundStyle(HVMColor.statusError)
        }
    }
}

// MARK: - 无 footer 的简化构造

extension HVMModal where Footer == EmptyView {
    public init(
        title: String,
        icon: ModalIcon = .none,
        width: CGFloat = 480,
        height: CGFloat? = nil,
        closeAction: (() -> Void)?,
        @ViewBuilder body: @escaping () -> Body
    ) {
        self.title = title
        self.icon = icon
        self.width = width
        self.height = height
        self.closeAction = closeAction
        self.bodyContent = body
        self.footerContent = nil
    }
}

/// HVMModal 底栏右对齐的按钮组. 主按钮放在最右.
public struct HVMModalFooter<Content: View>: View {
    let content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    public var body: some View {
        HStack(spacing: HVMSpace.sm) {
            Spacer(minLength: 0)
            content()
        }
    }
}
