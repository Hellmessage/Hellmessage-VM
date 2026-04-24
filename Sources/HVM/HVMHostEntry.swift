// HVMHostEntry.swift
// VMHost 进程的启动入口. 在 main.swift 通过 argv 分派后调用
//
// 职责:
//   1. 解析 bundle 路径, 抢 BundleLock (runtime 模式)
//   2. 加载 VMConfig, 构造 VMHandle
//   3. 启动 VM (异步)
//   4. 启动 IPC SocketServer, 监听 status / stop / kill 请求
//   5. RunLoop 驻留, 直到 VM 结束并收到关闭信号

import Foundation
import HVMBackend
import HVMBundle
import HVMCore
import HVMIPC

public enum HVMHostEntry {
    public static func run(bundlePath: String) -> Never {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        // 1. 载入 config
        let config: VMConfig
        do {
            config = try BundleIO.load(from: bundleURL)
        } catch {
            fputs("HVMHost: 加载 bundle 失败: \(error)\n", stderr)
            exit(3)
        }

        // 2. 抢锁, socketPath 用 runDir/<uuid>.sock
        let socketURL = HVMPaths.socketPath(for: config.id)
        do {
            try HVMPaths.ensure(HVMPaths.runDir)
        } catch {
            fputs("HVMHost: 创建 run 目录失败: \(error)\n", stderr)
            exit(1)
        }

        let lock: BundleLock
        do {
            lock = try BundleLock(bundleURL: bundleURL, mode: .runtime, socketPath: socketURL.path)
        } catch let e as HVMError {
            fputs("HVMHost: \(e.userFacing.message) (\(e.userFacing.code))\n", stderr)
            exit(4)
        } catch {
            fputs("HVMHost: 抢锁失败: \(error)\n", stderr)
            exit(4)
        }
        // lock 由进程生命周期持有; 退出时 release

        let startedAt = Date()

        // 3. 在 MainActor 启动 VM + IPC server
        Task { @MainActor in
            let handle = VMHandle(config: config, bundleURL: bundleURL)
            HostState.shared.vm = handle
            HostState.shared.startedAt = startedAt

            do {
                try await handle.start()
            } catch let e as HVMError {
                fputs("HVMHost: 启动 VM 失败: \(e.userFacing.message) (\(e.userFacing.code))\n", stderr)
                lock.release()
                exit(10)
            } catch {
                fputs("HVMHost: 启动 VM 失败: \(error)\n", stderr)
                lock.release()
                exit(10)
            }

            // VM 结束 -> 退出进程
            handle.addStateObserver { newState in
                if case .stopped = newState {
                    DispatchQueue.main.async {
                        HostState.shared.ipcServer?.stop()
                        lock.release()
                        exit(0)
                    }
                }
                if case .error = newState {
                    DispatchQueue.main.async {
                        HostState.shared.ipcServer?.stop()
                        lock.release()
                        exit(11)
                    }
                }
            }

            // 4. 启动 IPC
            let server = SocketServer(socketPath: socketURL)
            HostState.shared.ipcServer = server
            do {
                try server.start { req in
                    // 进入 MainActor 处理, 用 Box 绕过 Swift 6 sending 检查
                    let box = ResponseBox(
                        .failure(id: req.id, code: "ipc.internal", message: "未初始化")
                    )
                    let sem = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        box.value = HostState.shared.handle(req)
                        sem.signal()
                    }
                    sem.wait()
                    return box.value
                }
            } catch let e as HVMError {
                fputs("HVMHost: IPC server 启动失败: \(e.userFacing.message)\n", stderr)
                lock.release()
                exit(12)
            } catch {
                fputs("HVMHost: IPC server 启动失败: \(error)\n", stderr)
                lock.release()
                exit(12)
            }

            fputs("HVMHost: VM \(config.displayName) 已启动 (pid=\(getpid()))\n", stderr)
        }

        // 5. RunLoop 驻留
        RunLoop.main.run()
        exit(0)   // 理论到不了
    }
}

/// 跨线程传递 IPCResponse 的可变容器 (Swift 6 sending 检查绕过)
final class ResponseBox: @unchecked Sendable {
    var value: IPCResponse
    init(_ v: IPCResponse) { self.value = v }
}

/// VMHost 进程全局状态. 只在 @MainActor 访问
@MainActor
final class HostState {
    static let shared = HostState()
    var vm: VMHandle?
    var ipcServer: SocketServer?
    var startedAt: Date?

    func handle(_ req: IPCRequest) -> IPCResponse {
        guard let vm = self.vm else {
            return .failure(id: req.id, code: "backend.no_vm", message: "VM 未运行")
        }

        switch req.op {
        case IPCOp.status.rawValue:
            let payload = IPCStatusPayload(
                state: stateString(vm.state),
                id: vm.id.uuidString,
                bundlePath: vm.bundleURL.path,
                displayName: vm.config.displayName,
                guestOS: vm.config.guestOS.rawValue,
                cpuCount: vm.config.cpuCount,
                memoryMiB: vm.config.memoryMiB,
                pid: getpid(),
                startedAt: startedAt
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                return .failure(id: req.id, code: "ipc.encode_failed", message: "响应编码失败")
            }
            return .success(id: req.id, data: ["payload": json])

        case IPCOp.stop.rawValue:
            do {
                try vm.requestStop()
                return .success(id: req.id)
            } catch let e as HVMError {
                let uf = e.userFacing
                return .failure(id: req.id, code: uf.code, message: uf.message, details: uf.details)
            } catch {
                return .failure(id: req.id, code: "backend.vz_internal", message: "\(error)")
            }

        case IPCOp.kill.rawValue:
            Task { @MainActor in
                try? await vm.forceStop()
            }
            return .success(id: req.id)

        default:
            return .failure(id: req.id, code: "ipc.unknown_op",
                           message: "未知 op: \(req.op)")
        }
    }

    private func stateString(_ s: RunState) -> String {
        switch s {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .error(let msg): return "error:\(msg)"
        }
    }
}
