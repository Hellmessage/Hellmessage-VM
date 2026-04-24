// SidebarView.swift
// 左栏: VM 列表 + 底部 [+] 新建按钮
// 状态圆点颜色见 docs/GUI.md "VM 列表项"

import SwiftUI
import HVMBundle
import HVMCore

struct SidebarView: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        VStack(spacing: 0) {
            // 顶部: 标题 + 刷新
            HStack {
                Text("HVM")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(white: 0.95))
                Spacer()
                Text("\(model.list.count) VMs")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.55))
                Button(action: { model.refreshList() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.7))
                }
                .buttonStyle(.plain)
                .help("刷新列表")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().background(Color(white: 0.18))

            // 列表
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.list, id: \.id) { item in
                        rowView(for: item)
                            .background(
                                model.selectedID == item.id
                                    ? Color(white: 0.18)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedID = item.id }
                    }
                }
            }

            Spacer(minLength: 0)

            // 底部 [+] New VM
            Button(action: { model.showCreateWizard = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("New VM")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(Color(red: 0.36, green: 0.55, blue: 1.0))
            }
            .buttonStyle(.plain)
            .background(Color(white: 0.08))
        }
    }

    @ViewBuilder
    private func rowView(for item: AppModel.VMListItem) -> some View {
        let isRunning = model.sessions[item.id] != nil || item.runState == "running"
        HStack(spacing: 10) {
            // 状态圆点
            Circle()
                .fill(statusColor(isRunning: isRunning))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 0.92))
                    .lineLimit(1)
                Text("\(item.guestOS.rawValue) · \(isRunning ? "running" : "stopped")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func statusColor(isRunning: Bool) -> Color {
        isRunning ? Color(red: 0.3, green: 0.83, blue: 0.39)
                  : Color(white: 0.4)
    }
}
