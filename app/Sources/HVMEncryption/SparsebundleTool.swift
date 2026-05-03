// HVMEncryption/SparsebundleTool.swift
// 加密 sparsebundle 工具层: 包 macOS hdiutil 子命令 (create / attach / detach / info / chpass).
// 设计稿见 docs/v3/ENCRYPTION.md "方案 A".
//
// 严格约束:
//   - 加密算法固定 AES-256, 文件系统固定 APFS, 镜像格式固定 SPARSEBUNDLE
//   - 密码绝不进 argv (会被 ps 看到), 一律走 stdin (-stdinpass / -oldstdinpass / -newstdinpass)
//     null-terminated 写入 (hdiutil 要求 NUL 结尾)
//   - hdiutil -plist 输出走 PropertyListSerialization 解析, 不靠正则文本
//   - 上层 (后续 PR-3 EncryptedBundleIO) 持有 KEK; 本工具层只在调用栈内借用 password 字符串,
//     不缓存 / 不 log
//
// 不暴露的设计决定: layout=NONE (无分区图, sparsebundle 整体即 APFS volume), spotlight=off.
// 这两项写死避免 hdiutil 默认值变动导致挂载行为漂移.

import Foundation
import Darwin
import HVMCore

public enum SparsebundleTool {
    private static let log = HVMLog.logger("encryption.sparsebundle")

    // MARK: - 选项 / 返回类型

    public struct CreateOptions: Sendable {
        /// 容器上限. 实际占用按写入数据增长 (sparse), 但容器达此值后写满.
        public var sizeBytes: UInt64
        /// attach 后 APFS volume 的 label (诊断用; 非业务 ID, 与 mountpoint 无关).
        /// 限 alphanumeric+`-_`; 上层应保证只传可控字符 (本函数不做校验, 仅传给 hdiutil).
        public var volumeName: String
        /// sparsebundle band 大小. nil = hdiutil 默认 (8 MiB). 仅诊断 / benchmark 用,
        /// 业务侧通常用默认.
        public var bandSizeBytes: UInt64?

        public init(sizeBytes: UInt64, volumeName: String, bandSizeBytes: UInt64? = nil) {
            self.sizeBytes = sizeBytes
            self.volumeName = volumeName
            self.bandSizeBytes = bandSizeBytes
        }
    }

    public struct AttachInfo: Sendable, Equatable {
        /// 实际 mountpoint (= 调用方传入的 mountpoint). hdiutil 也会按此挂载.
        public let mountpoint: URL
        /// 关联的字符设备 (例 "/dev/disk5"). detach 时也可用此参数.
        public let devNode: String
    }

    public struct InfoEntry: Sendable, Equatable {
        /// 镜像源文件路径, 例 ".../Foo.hvmz.sparsebundle"
        public let imagePath: String
        /// 当前挂载点, nil 表示已 attach 但未 mount (suppressed) 或解析不到
        public let mountpoint: String?
        /// 字符设备 (主), 例 "/dev/disk5"
        public let devNode: String
    }

    // MARK: - create

    /// 创建加密 sparsebundle. 已存在则抛 .sparsebundleAlreadyExists, 不覆盖.
    /// 失败时 hdiutil 自身会清理半成品 (无需本函数兜底).
    public static func create(at sparsebundleURL: URL,
                              password: String,
                              options: CreateOptions) throws {
        if FileManager.default.fileExists(atPath: sparsebundleURL.path) {
            throw HVMError.encryption(.sparsebundleAlreadyExists(path: sparsebundleURL.path))
        }
        // 父目录必须存在 (hdiutil 不会 mkdir -p)
        let parent = sparsebundleURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var args: [String] = [
            "create",
            "-encryption", "AES-256",
            "-stdinpass",
            "-size", "\(options.sizeBytes)b",
            "-fs", "APFS",
            "-volname", options.volumeName,
            "-type", "SPARSEBUNDLE",
            "-layout", "NONE",
            "-nospotlight",
        ]
        if let band = options.bandSizeBytes {
            // band-size 单位是 512 字节 sectors
            let sectors = (band + 511) / 512
            args.append(contentsOf: ["-imagekey", "sparse-band-size=\(sectors)"])
        }
        args.append(sparsebundleURL.path)

        Self.log.info("sparsebundle create: path=\(sparsebundleURL.lastPathComponent, privacy: .public) sizeBytes=\(options.sizeBytes) volname=\(options.volumeName, privacy: .public)")
        _ = try runHdiutil(verb: "create", args: args, stdinPasswords: [password])
    }

    // MARK: - attach

    /// 挂载加密 sparsebundle. 密码错抛 .wrongPassword.
    /// mountpoint 必须不存在 / 为空目录 — 调用方负责清理 (本函数不 mkdir, hdiutil 会自动建).
    public static func attach(at sparsebundleURL: URL,
                              password: String,
                              mountpoint: URL) throws -> AttachInfo {
        // 防 stale: mountpoint 已被占用直接抛
        if isMountpointBusy(mountpoint: mountpoint) {
            throw HVMError.encryption(.mountpointInUse(path: mountpoint.path))
        }

        let args: [String] = [
            "attach",
            "-stdinpass",
            "-nobrowse",
            "-noverify",
            "-noautofsck",
            "-noautoopen",
            "-mountpoint", mountpoint.path,
            "-plist",
            sparsebundleURL.path,
        ]
        Self.log.info("sparsebundle attach: \(sparsebundleURL.lastPathComponent, privacy: .public) → \(mountpoint.path, privacy: .public)")

        let output: Data
        do {
            output = try runHdiutil(verb: "attach", args: args, stdinPasswords: [password])
        } catch let HVMError.encryption(.hdiutilFailed(verb, code, stderr)) {
            if isAuthError(stderr) {
                throw HVMError.encryption(.wrongPassword)
            }
            throw HVMError.encryption(.hdiutilFailed(verb: verb, exitCode: code, stderr: stderr))
        }

        guard let dev = parseAttachDevNode(plistData: output, expectedMountpoint: mountpoint) else {
            // 兜底: hdiutil 已 attach 成功但 plist 解析不出 devNode → detach 后抛
            try? detach(mountpoint: mountpoint, force: true)
            throw HVMError.encryption(.parseFailed(reason: "hdiutil attach -plist 中找不到 dev-entry / mount-point"))
        }
        return AttachInfo(mountpoint: mountpoint, devNode: dev)
    }

    // MARK: - detach

    /// 卸载. force=true 走 -force, 适合 stale 兜底 (但可能丢未刷写的 dirty pages).
    /// mountpoint 已经不存在 (= 已被 detach) 时本函数 noop.
    public static func detach(mountpoint: URL, force: Bool = false) throws {
        // 已经卸载就 noop
        if !isMountpointBusy(mountpoint: mountpoint) {
            return
        }
        var args: [String] = ["detach", mountpoint.path]
        if force { args.append("-force") }
        Self.log.info("sparsebundle detach: \(mountpoint.path, privacy: .public) force=\(force)")
        _ = try runHdiutil(verb: "detach", args: args, stdinPasswords: [])
    }

    // MARK: - info

    /// 列当前已 attach 的所有 disk image (含非 sparsebundle).
    /// 调用方可按 imagePath 后缀 / mountpoint 前缀过滤出 HVM 自家的 stale mount.
    public static func info() throws -> [InfoEntry] {
        let output = try runHdiutil(verb: "info", args: ["info", "-plist"], stdinPasswords: [])
        return parseInfoEntries(plistData: output)
    }

    // MARK: - chpass

    /// 改密 (rekey). 不重密底层 DEK, 只换 KEK; 几毫秒完成.
    /// 老密码错抛 .wrongPassword.
    public static func chpass(at sparsebundleURL: URL,
                              oldPassword: String,
                              newPassword: String) throws {
        let args: [String] = [
            "chpass",
            "-oldstdinpass",
            "-newstdinpass",
            sparsebundleURL.path,
        ]
        Self.log.info("sparsebundle chpass: \(sparsebundleURL.lastPathComponent, privacy: .public)")
        do {
            _ = try runHdiutil(verb: "chpass",
                               args: args,
                               stdinPasswords: [oldPassword, newPassword])
        } catch let HVMError.encryption(.hdiutilFailed(verb, code, stderr)) {
            if isAuthError(stderr) {
                throw HVMError.encryption(.wrongPassword)
            }
            throw HVMError.encryption(.hdiutilFailed(verb: verb, exitCode: code, stderr: stderr))
        }
    }

    /// hdiutil "认证错误" 多语言识别 — 系统语言会本地化 stderr, 必须列出所有已知翻译.
    /// 兜底匹配 "error 35" (DIHLDiskImageAttach error 35 = 密码错, 语言无关).
    private static func isAuthError(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        // 英文 (en) / 中文简 / 中文繁 / 日 / 西班牙 / 法 / 德
        let keywords = [
            "authentication",
            "incorrect passphrase",
            "error 35",
            "认证",        // zh-Hans
            "認證",        // zh-Hant
            "認証",        // ja
            "autenticación",  // es
            "authentification",  // fr
            "authentifizierung", // de
        ]
        for kw in keywords where s.contains(kw.lowercased()) {
            return true
        }
        return false
    }

    // MARK: - 内部

    /// 调 hdiutil. 多个密码按顺序 NUL-terminated 写 stdin (hdiutil 要求).
    /// stdout (通常 -plist 输出) 作为 Data 返回; stderr 仅在错误时拿来诊断.
    @discardableResult
    private static func runHdiutil(verb: String,
                                   args: [String],
                                   stdinPasswords: [String]) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if !stdinPasswords.isEmpty {
            proc.standardInput = Pipe()
        }

        do {
            try proc.run()
        } catch {
            throw HVMError.encryption(.hdiutilFailed(verb: verb, exitCode: -1,
                                                     stderr: "无法启动 hdiutil: \(error)"))
        }

        if !stdinPasswords.isEmpty,
           let stdinHandle = (proc.standardInput as? Pipe)?.fileHandleForWriting {
            for pw in stdinPasswords {
                if var data = pw.data(using: .utf8) {
                    data.append(0)  // NUL 终止 (hdiutil -stdinpass 要求)
                    do {
                        try stdinHandle.write(contentsOf: data)
                    } catch {
                        // hdiutil 已退出 → write 报 EPIPE, 不致命, 后面 waitUntilExit 处理
                    }
                }
            }
            try? stdinHandle.close()
        }

        proc.waitUntilExit()

        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            Self.log.error("hdiutil \(verb, privacy: .public) 失败 status=\(proc.terminationStatus) stderr=\(errStr, privacy: .public)")
            throw HVMError.encryption(.hdiutilFailed(verb: verb,
                                                     exitCode: proc.terminationStatus,
                                                     stderr: errStr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return outData
    }

    /// hdiutil attach -plist 输出结构 (节选):
    /// {
    ///   system-entities = (
    ///     { content-hint = "Apple_APFS_Container"; dev-entry = "/dev/disk5"; ... },
    ///     { content-hint = "Apple_APFS"; dev-entry = "/dev/disk5s1"; mount-point = "/path/..."; ... }
    ///   )
    /// }
    /// 我们要的是 dev-entry: 取**第一个 dev-entry** (= 容器主设备 /dev/diskN, 不带 sN).
    /// mountpoint 已知 (调用方传入), 不再从 plist 取.
    private static func parseAttachDevNode(plistData: Data, expectedMountpoint: URL) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                      options: [],
                                                                      format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }
        for ent in entities {
            if let dev = ent["dev-entry"] as? String {
                // 取主设备 (无 sN 后缀); 例 /dev/disk5 而非 /dev/disk5s1
                if !dev.contains("s"),
                   let last = dev.split(separator: "/").last,
                   last.hasPrefix("disk") {
                    return dev
                }
                // 兜底: 第一个就用
                return dev
            }
        }
        return nil
    }

    /// hdiutil info -plist 顶层结构 (节选):
    /// {
    ///   images = (
    ///     {
    ///       image-path = ".../foo.sparsebundle";
    ///       system-entities = ( { dev-entry = "/dev/disk5"; mount-point = "/path/..."; }, ... );
    ///     },
    ///     ...
    ///   );
    /// }
    private static func parseInfoEntries(plistData: Data) -> [InfoEntry] {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData,
                                                                      options: [],
                                                                      format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            return []
        }
        var out: [InfoEntry] = []
        for img in images {
            guard let path = img["image-path"] as? String else { continue }
            let entities = img["system-entities"] as? [[String: Any]] ?? []
            // 主 devNode = 不带 s<N> 的 /dev/diskN
            let mainDev = entities
                .compactMap { $0["dev-entry"] as? String }
                .first { dev in
                    guard let last = dev.split(separator: "/").last else { return false }
                    return last.hasPrefix("disk") && !last.contains("s")
                } ?? entities.compactMap { $0["dev-entry"] as? String }.first ?? ""
            // mountpoint = 任意带 mount-point 的 entity
            let mp = entities
                .compactMap { $0["mount-point"] as? String }
                .first { !$0.isEmpty }
            out.append(InfoEntry(imagePath: path, mountpoint: mp, devNode: mainDev))
        }
        return out
    }

    /// 检测 mountpoint 是否已被某 disk image 占据 (info 列表里有它)
    private static func isMountpointBusy(mountpoint: URL) -> Bool {
        let normalized = mountpoint.standardizedFileURL.path
        guard let entries = try? info() else { return false }
        return entries.contains { entry in
            guard let mp = entry.mountpoint else { return false }
            return URL(fileURLWithPath: mp).standardizedFileURL.path == normalized
        }
    }
}
