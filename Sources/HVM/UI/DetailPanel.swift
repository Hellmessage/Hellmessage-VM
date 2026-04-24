// DetailPanel.swift
// 右栏三态:
//   - 未选中: 空态提示
//   - 选中 stopped/paused: 缩略图 + 配置摘要 + [Start]/[Delete]
//   - 选中 running 嵌入态: VZVirtualMachineView 实时画面 + [Stop]/[Kill]/[弹出]
//   - 选中 running 独立态: 占位 "正在独立窗口" + [嵌入]/[Stop]/[Kill]

import AppKit
import SwiftUI
import HVMBackend
import HVMBundle
import HVMCore
import HVMDisplay

struct DetailPanel: View {
    @Bindable var model: AppModel
    @Bindable var errors: ErrorPresenter

    var body: some View {
        if let item = model.selectedItem {
            content(for: item)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.box")
                .font(.system(size: 48))
                .foregroundStyle(Color(white: 0.3))
            Text("选择左侧 VM 查看详情")
                .foregroundStyle(Color(white: 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for item: AppModel.VMListItem) -> some View {
        if let session = model.sessions[item.id] {
            runningContent(session: session, item: item)
        } else {
            stoppedContent(item: item)
        }
    }

    // MARK: - running

    @ViewBuilder
    private func runningContent(session: VMSession, item: AppModel.VMListItem) -> some View {
        VStack(spacing: 0) {
            // 顶部 status bar
            HStack {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text("·")
                    .foregroundStyle(Color(white: 0.4))
                Text(stateText(session.state))
                    .foregroundStyle(Color(red: 0.3, green: 0.83, blue: 0.39))
                Spacer()
                if session.displayMode == .embedded {
                    Button(action: { model.popOutStandalone(item.id) }) {
                        Label("弹出", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                } else if session.displayMode == .standalone {
                    Button(action: { model.embedInMain(item.id) }) {
                        Label("嵌入", systemImage: "arrow.down.right.square")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(white: 0.09))

            Divider().background(Color(white: 0.18))

            // 中间: 嵌入 view 或占位
            ZStack {
                Color.black
                if session.displayMode == .embedded {
                    EmbeddedVMContent(attachment: session.attachment)
                } else {
                    // 独立窗口态占位
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 36))
                            .foregroundStyle(Color(white: 0.35))
                        Text("正在独立窗口运行")
                            .foregroundStyle(Color(white: 0.6))
                        Button("嵌入到此") { model.embedInMain(item.id) }
                    }
                }
            }

            // 底部: 配置摘要 + 操作
            Divider().background(Color(white: 0.18))
            HStack {
                Text("\(item.config.cpuCount) 核 · \(item.config.memoryMiB / 1024) GiB · \(networkSummary(item.config))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.55))
                Spacer()
                Button("Stop") {
                    do { try model.stop(item.id) }
                    catch { errors.present(error) }
                }
                Button("Kill", role: .destructive) {
                    Task {
                        do { try await model.kill(item.id) }
                        catch { errors.present(error) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - stopped

    @ViewBuilder
    private func stoppedContent(item: AppModel.VMListItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 标题
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .font(.system(size: 22, weight: .semibold))
                    Text("\(item.guestOS.rawValue) · \(item.runState)")
                        .foregroundStyle(Color(white: 0.55))
                }

                // 缩略图
                if let img = ThumbnailGenerator.load(from: item.bundleURL) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480)
                        .background(Color.black)
                        .cornerRadius(6)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black)
                        .frame(width: 480, height: 300)
                        .overlay(
                            Image(systemName: "cube.box")
                                .font(.system(size: 40))
                                .foregroundStyle(Color(white: 0.25))
                        )
                }

                // 配置摘要
                VStack(alignment: .leading, spacing: 6) {
                    kv("id", item.config.id.uuidString)
                    kv("cpu", "\(item.config.cpuCount) 核")
                    kv("memory", "\(item.config.memoryMiB / 1024) GiB")
                    kv("main disk", "\(item.config.disks.first?.sizeGiB ?? 0) GiB")
                    if let iso = item.config.installerISO {
                        kv("iso", iso)
                    }
                    kv("bootFromDisk", "\(item.config.bootFromDiskOnly)")
                    kv("network", networkSummary(item.config))
                    kv("bundle", item.bundleURL.path)
                }
                .font(.system(size: 12, design: .monospaced))

                // 操作按钮
                HStack(spacing: 10) {
                    Button(action: { startAction(item) }) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        deleteAction(item)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Spacer()
                }
            }
            .padding(20)
        }
    }

    private func startAction(_ item: AppModel.VMListItem) {
        Task {
            do {
                try await model.start(item)
            } catch {
                errors.present(error)
            }
        }
    }

    private func deleteAction(_ item: AppModel.VMListItem) {
        do {
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: item.bundleURL, resultingItemURL: &resultURL)
            model.refreshList()
        } catch {
            errors.present(error)
        }
    }

    // MARK: - 小工具

    @ViewBuilder
    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key + ":")
                .foregroundStyle(Color(white: 0.5))
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .foregroundStyle(Color(white: 0.85))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func networkSummary(_ config: VMConfig) -> String {
        guard let net = config.networks.first else { return "(无网卡)" }
        switch net.mode {
        case .nat: return "nat · \(net.macAddress)"
        case .bridged(let iface): return "bridged(\(iface)) · \(net.macAddress)"
        }
    }

    private func stateText(_ s: RunState) -> String {
        switch s {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .error: return "error"
        }
    }
}
