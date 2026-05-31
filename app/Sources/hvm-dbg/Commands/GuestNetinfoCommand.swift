// hvm-dbg guest-netinfo — 拉 guest 网卡 + IP (qemu-ga guest-network-get-interfaces).
//
// 验证 guest IP 通路 (GUI 详情页同源 IPC guest.netinfo). 前提: guest 内 qemu-ga 在跑.
// 用法: hvm-dbg guest-netinfo <vm> [--format human|json]

import ArgumentParser
import Foundation
import HVMBundle
import HVMCore
import HVMIPC

struct GuestNetinfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guest-netinfo",
        abstract: "拉 guest 网卡 + IP (qemu-ga); GUI 详情页 guest IP 同源"
    )

    @Argument(help: "VM 名称或 bundle 路径")
    var vm: String

    @Option(name: .long, help: "qga 超时秒数 (default 10)")
    var timeoutSec: Int = 10

    @Option(name: .long, help: "输出格式: human | json (default human)")
    var format: OutputFormat = .human

    func run() async throws {
        do {
            let socketPath = try IPCCall.socketPath(forVM: vm)
            let resp = try IPCCall.send(
                socketPath: socketPath, op: .guestNetInfo,
                args: ["timeoutSec": "\(timeoutSec)"],
                timeoutSec: timeoutSec + 5
            )
            guard let json = resp.data?["payload"],
                  let data = json.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCGuestNetInfoPayload.self, from: data) else {
                throw HVMError.ipc(.decodeFailed(reason: "guest-netinfo payload"))
            }
            switch format {
            case .json:
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let out = try? enc.encode(payload), let s = String(data: out, encoding: .utf8) {
                    print(s)
                }
            case .human:
                print("主 IPv4: \(payload.primaryIPv4 ?? "(未知 — guest 未配网 / 无 qemu-ga)")")
                for i in payload.interfaces {
                    let ips = i.ips.map { "\($0.address)/\($0.prefix.map(String.init) ?? "?") (\($0.type))" }
                        .joined(separator: ", ")
                    print("  \(i.name) [\(i.mac ?? "?")]: \(ips.isEmpty ? "(无 IP)" : ips)")
                }
            }
        } catch {
            format == .json ? bailJSON(error) : bail(error)
        }
    }
}
