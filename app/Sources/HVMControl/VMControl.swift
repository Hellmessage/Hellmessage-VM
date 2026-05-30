// VMControl.swift
// VM 动作门面 — 收口启停/删除. CLI 命令 + 新 GUI store 共用同一套, 不再各写各的.
//
// start: 委托 HostLauncher.launch (fork --host-mode-bundle 子进程).
// stop/kill/status: 走 BundleLock.inspect 拿 socketPath → SocketClient IPC.
// delete: requireStopped 检查 → 废纸篓 / purge / secure-erase.
//
// 注意: 调用方 (CLI tty prompt / GUI dialog) 负责加密 VM 的密码获取; VMControl 只透传.

import Foundation
import HVMBundle
import HVMCore
import HVMEncryption
import HVMIPC

public enum VMControl {

    // MARK: - 启动

    /// 启动 VM (fork --host-mode-bundle 子进程, 立即返回 pid).
    /// 加密 VM 必须传 password (调用方负责 prompt); 明文传 nil.
    /// 已 running (锁被占) 抛 HVMError.bundle(.busy).
    @discardableResult
    public static func start(bundleURL: URL, password: String?) throws -> Int32 {
        if BundleLock.isBusy(bundleURL: bundleURL) {
            let holder = BundleLock.inspect(bundleURL: bundleURL)
            throw HVMError.bundle(.busy(
                pid: holder?.pid ?? 0,
                holderMode: holder?.mode ?? "unknown"
            ))
        }
        return try HostLauncher.launch(bundleURL: bundleURL, password: password)
    }

    // MARK: - 停止

    /// 软关机 (ACPI). 未运行 / socket 缺失抛 HVMError.ipc(.socketNotFound).
    public static func stop(bundleURL: URL) throws {
        try sendControl(bundleURL: bundleURL, op: .stop, failMessage: "stop 失败")
    }

    /// 强制关机 (拔电源, 可能丢数据).
    public static func kill(bundleURL: URL) throws {
        try sendControl(bundleURL: bundleURL, op: .kill, failMessage: "kill 失败")
    }

    /// 查询运行态详情 (state / pid / startedAt). 未运行返回 nil.
    public static func status(bundleURL: URL) throws -> IPCStatusPayload? {
        guard BundleLock.isBusy(bundleURL: bundleURL),
              let holder = BundleLock.inspect(bundleURL: bundleURL),
              !holder.socketPath.isEmpty else {
            return nil
        }
        let req = IPCRequest(op: IPCOp.status.rawValue)
        guard let resp = try? SocketClient.request(socketPath: holder.socketPath, request: req),
              resp.ok,
              let jsonStr = resp.data?["payload"],
              let jsonData = jsonStr.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(IPCStatusPayload.self, from: jsonData)
    }

    /// stop/kill 共用: inspect → SocketClient.request → 校验 resp.ok
    private static func sendControl(bundleURL: URL, op: IPCOp, failMessage: String) throws {
        guard let holder = BundleLock.inspect(bundleURL: bundleURL),
              !holder.socketPath.isEmpty else {
            throw HVMError.ipc(.socketNotFound(path: "(inspect 失败)"))
        }
        let req = IPCRequest(op: op.rawValue)
        let resp = try SocketClient.request(socketPath: holder.socketPath, request: req)
        guard resp.ok else {
            throw HVMError.ipc(.remoteError(
                code: resp.error?.code ?? "ipc.remote_error",
                message: resp.error?.message ?? failMessage
            ))
        }
    }

    // MARK: - 删除

    public enum DeleteMode: Sendable {
        case trash         // 移废纸篓 (默认, 可恢复)
        case purge         // 彻底 removeItem
        case secureErase   // 单 pass random 覆写 (加密 VM 防取证)
    }

    /// 删除 bundle. 必须 stopped (running 抛 HVMError.bundle(.busy)).
    public static func delete(bundleURL: URL, mode: DeleteMode) throws {
        if BundleLock.isBusy(bundleURL: bundleURL) {
            let holder = BundleLock.inspect(bundleURL: bundleURL)
            throw HVMError.bundle(.busy(
                pid: holder?.pid ?? 0,
                holderMode: holder?.mode ?? "runtime"
            ))
        }
        switch mode {
        case .trash:
            var resultURL: NSURL?
            try FileManager.default.trashItem(at: bundleURL, resultingItemURL: &resultURL)
        case .purge:
            try FileManager.default.removeItem(at: bundleURL)
        case .secureErase:
            SecureErase.eraseDirectory(at: bundleURL)
        }
    }
}
