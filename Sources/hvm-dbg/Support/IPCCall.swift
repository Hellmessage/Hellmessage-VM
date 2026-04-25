// hvm-dbg/Support/IPCCall.swift
// 把 "用 vm 名/路径找 socket → 发 IPC → 解析 response" 这串重复操作收一处.
// hvm-dbg 所有子命令都是这模式.

import Foundation
import HVMBundle
import HVMCore
import HVMIPC

public enum IPCCall {
    /// 找 bundle 的运行时 socket. busy=false 或没记录 socketPath 时抛 vm 未运行.
    public static func socketPath(forVM ref: String) throws -> String {
        let bundleURL = try BundleResolve.resolve(ref)
        guard BundleLock.isBusy(bundleURL: bundleURL) else {
            throw HVMError.ipc(.socketNotFound(path: bundleURL.path))
        }
        guard let holder = BundleLock.inspect(bundleURL: bundleURL),
              !holder.socketPath.isEmpty else {
            throw HVMError.ipc(.socketNotFound(path: bundleURL.path))
        }
        return holder.socketPath
    }

    /// 发 IPC 请求, 失败 throw HVMError. 成功返回 response.
    public static func send(socketPath: String, op: IPCOp,
                            args: [String: String] = [:],
                            timeoutSec: Int = 10) throws -> IPCResponse {
        let req = IPCRequest(op: op.rawValue, args: args)
        let resp = try SocketClient.request(socketPath: socketPath, request: req, timeoutSec: timeoutSec)
        if !resp.ok {
            let e = resp.error
            throw HVMError.ipc(.remoteError(
                code: e?.code ?? "unknown",
                message: e?.message ?? "unknown error"
            ))
        }
        return resp
    }
}
