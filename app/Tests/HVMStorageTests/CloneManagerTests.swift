// HVMStorageTests/CloneManagerTests.swift
// 整 VM 克隆覆盖. 所有测试都用临时目录 fixture, 不依赖真实 VM / qemu-img.
// 设计稿见 docs/v3/CLONE.md (T1 / C1 / C3 等真机验证不在单测覆盖).

import XCTest
@testable import HVMStorage
@testable import HVMBundle
@testable import HVMCore
@testable import HVMNet

final class CloneManagerTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-clone-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let d = tmpRoot { try? FileManager.default.removeItem(at: d) }
    }

    // MARK: - fixture helpers

    /// 构造一个最小可用的 fixture bundle (config.yaml + 主盘文件 + 必要子目录).
    /// 不真正调用 BundleIO.create (那会要求 ConfigBuilder 等), 而是手工写文件 + BundleIO.save.
    @discardableResult
    private func makeFixtureBundle(displayName: String,
                                   guestOS: GuestOSType,
                                   engine: Engine,
                                   numDataDisks: Int = 0,
                                   includeSnapshot: Bool = false) throws -> (URL, VMConfig) {
        let bundleURL = tmpRoot.appendingPathComponent("\(displayName).hvmz", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: BundleLayout.disksDir(bundleURL), withIntermediateDirectories: true)
        try fm.createDirectory(at: BundleLayout.logsDir(bundleURL), withIntermediateDirectories: true)
        try fm.createDirectory(at: BundleLayout.metaDir(bundleURL), withIntermediateDirectories: true)

        let diskFormat: DiskFormat = (engine == .vz) ? .raw : .qcow2

        // 主盘 (内容是占位字节, 测试只比对内容一致, 不真正挂磁盘)
        let mainName = BundleLayout.mainDiskFileName(for: engine)
        let mainRel = "\(BundleLayout.disksDirName)/\(mainName)"
        let mainURL = bundleURL.appendingPathComponent(mainRel)
        let mainContent = "MAIN-DISK-\(UUID().uuidString)".data(using: .utf8)!
        try mainContent.write(to: mainURL)

        var disks = [DiskSpec(role: .main, path: mainRel, sizeGiB: 1, format: diskFormat)]

        for _ in 0..<numDataDisks {
            let uuid8 = DiskFactory.newDataDiskUUID8()
            let dataName = BundleLayout.dataDiskFileName(uuid8: uuid8, engine: engine)
            let dataRel = "\(BundleLayout.disksDirName)/\(dataName)"
            let dataURL = bundleURL.appendingPathComponent(dataRel)
            try ("DATA-\(uuid8)-\(UUID().uuidString)".data(using: .utf8)!).write(to: dataURL)
            disks.append(DiskSpec(role: .data, path: dataRel, sizeGiB: 1, format: diskFormat))
        }

        let networks = [
            NetworkSpec(mode: .user, macAddress: "02:11:22:33:44:55"),
            NetworkSpec(mode: .user, macAddress: "02:aa:bb:cc:dd:ee"),
        ]

        // OS 特定子目录
        switch guestOS {
        case .linux, .windows:
            try fm.createDirectory(at: BundleLayout.nvramDir(bundleURL), withIntermediateDirectories: true)
            let nvram = BundleLayout.nvramURL(bundleURL)
            try ("NVRAM-\(UUID().uuidString)".data(using: .utf8)!).write(to: nvram)
        case .macOS:
            let auxDir = BundleLayout.auxiliaryDir(bundleURL)
            try fm.createDirectory(at: auxDir, withIntermediateDirectories: true)
            try ("AUX-STORAGE-\(UUID().uuidString)".data(using: .utf8)!)
                .write(to: auxDir.appendingPathComponent(BundleLayout.auxStorageName))
            try ("HW-MODEL-\(UUID().uuidString)".data(using: .utf8)!)
                .write(to: auxDir.appendingPathComponent(BundleLayout.hardwareModel))
            try ("MACHINE-ID-\(UUID().uuidString)".data(using: .utf8)!)
                .write(to: auxDir.appendingPathComponent(BundleLayout.machineIdentifier))
        }

        if guestOS == .windows {
            let tpmDir = BundleLayout.tpmStateDir(bundleURL)
            try fm.createDirectory(at: tpmDir, withIntermediateDirectories: true)
            try ("TPM-PERMALL-\(UUID().uuidString)".data(using: .utf8)!)
                .write(to: tpmDir.appendingPathComponent("permall"))
        }

        // 缩略图
        try ("THUMB-\(UUID().uuidString)".data(using: .utf8)!)
            .write(to: BundleLayout.metaDir(bundleURL)
                       .appendingPathComponent(BundleLayout.thumbnailName))

        // 可选 snapshot 占位
        if includeSnapshot {
            let snap = BundleLayout.snapshotDir(bundleURL, name: "test-snap")
            try fm.createDirectory(at: snap.appendingPathComponent(BundleLayout.disksDirName),
                                  withIntermediateDirectories: true)
            try ("SNAP-META-\(UUID().uuidString)".data(using: .utf8)!)
                .write(to: snap.appendingPathComponent("meta.json"))
        }

        var config = VMConfig(
            displayName: displayName,
            guestOS: guestOS,
            engine: engine,
            cpuCount: 2,
            memoryMiB: 2048,
            disks: disks,
            networks: networks
        )
        // OS-specific spec 字段 — VMConfig.validate 只看 engine/guestOS 组合, 不强制 spec 存在
        switch guestOS {
        case .macOS:   config.macOS = MacOSSpec()
        case .linux:   config.linux = LinuxSpec()
        case .windows: config.windows = WindowsSpec()
        }
        try BundleIO.save(config: config, to: bundleURL)

        return (bundleURL, config)
    }

    private func sha256(of url: URL) throws -> Data {
        // 简化: 直接读全文比对; fixture 文件极小
        return try Data(contentsOf: url)
    }

    // MARK: - 1. 基本 Linux + VZ 克隆

    func testCloneBasicLinuxVZ() throws {
        let (src, srcCfg) = try makeFixtureBundle(displayName: "Foo",
                                                  guestOS: .linux,
                                                  engine: .vz)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "Bar")
        )

        XCTAssertEqual(result.targetBundle.lastPathComponent, "Bar.hvmz")
        XCTAssertNotEqual(result.newID, srcCfg.id, "id 必须重生")

        // 主盘存在 + 内容一致
        let srcMain = src.appendingPathComponent(srcCfg.disks[0].path)
        let dstMain = result.targetBundle.appendingPathComponent(srcCfg.disks[0].path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstMain.path))
        XCTAssertEqual(try sha256(of: srcMain), try sha256(of: dstMain),
                       "主盘内容应通过 clonefile 保持一致")

        // 目标 config 加载得回, displayName + id 已变
        let dstCfg = try BundleIO.load(from: result.targetBundle)
        XCTAssertEqual(dstCfg.displayName, "Bar")
        XCTAssertEqual(dstCfg.id, result.newID)
        XCTAssertNotEqual(dstCfg.id, srcCfg.id)

        // nvram 也克隆过来
        let srcNvram = BundleLayout.nvramURL(src)
        let dstNvram = BundleLayout.nvramURL(result.targetBundle)
        XCTAssertEqual(try sha256(of: srcNvram), try sha256(of: dstNvram))
    }

    // MARK: - 2. macOS guest: machine-identifier 重生

    func testCloneMacOSRegeneratesMachineIdentifier() throws {
        let (src, _) = try makeFixtureBundle(displayName: "MacSrc",
                                              guestOS: .macOS,
                                              engine: .vz)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "MacClone")
        )

        let srcID = try sha256(of: BundleLayout.auxiliaryDir(src)
                                   .appendingPathComponent(BundleLayout.machineIdentifier))
        let dstID = try sha256(of: BundleLayout.auxiliaryDir(result.targetBundle)
                                   .appendingPathComponent(BundleLayout.machineIdentifier))
        XCTAssertNotEqual(srcID, dstID, "machine-identifier 字节必须重生 (与源不同)")
    }

    // MARK: - 3. macOS guest: hardware-model 保留

    func testCloneMacOSKeepsHardwareModel() throws {
        let (src, _) = try makeFixtureBundle(displayName: "MacHW",
                                              guestOS: .macOS,
                                              engine: .vz)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "MacHWClone")
        )

        let srcHW = try sha256(of: BundleLayout.auxiliaryDir(src)
                                    .appendingPathComponent(BundleLayout.hardwareModel))
        let dstHW = try sha256(of: BundleLayout.auxiliaryDir(result.targetBundle)
                                    .appendingPathComponent(BundleLayout.hardwareModel))
        XCTAssertEqual(srcHW, dstHW, "hardware-model 必须保留 (与 IPSW 装机绑定, 不可改)")

        // aux-storage 同理
        let srcAux = try sha256(of: BundleLayout.auxiliaryDir(src)
                                    .appendingPathComponent(BundleLayout.auxStorageName))
        let dstAux = try sha256(of: BundleLayout.auxiliaryDir(result.targetBundle)
                                    .appendingPathComponent(BundleLayout.auxStorageName))
        XCTAssertEqual(srcAux, dstAux)
    }

    // MARK: - 4. 数据盘 uuid8 重生

    func testCloneDataDisksGetNewUUID8() throws {
        let (src, srcCfg) = try makeFixtureBundle(displayName: "DataSrc",
                                                  guestOS: .linux,
                                                  engine: .vz,
                                                  numDataDisks: 2)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "DataClone")
        )

        XCTAssertEqual(result.renamedDataDiskUUID8s.count, 2,
                       "两块数据盘应都被记录")

        let dstCfg = try BundleIO.load(from: result.targetBundle)
        let srcDataPaths = Set(srcCfg.disks.filter { $0.role == .data }.map(\.path))
        let dstDataPaths = Set(dstCfg.disks.filter { $0.role == .data }.map(\.path))

        // 数据盘路径在 config 里改了
        XCTAssertEqual(srcDataPaths.count, 2)
        XCTAssertEqual(dstDataPaths.count, 2)
        XCTAssertTrue(srcDataPaths.isDisjoint(with: dstDataPaths),
                      "数据盘 path 应全部更新 (老 uuid8 → 新 uuid8)")

        // 物理文件按新名字落盘, 内容与源一一对应
        for (i, srcDisk) in srcCfg.disks.enumerated() where srcDisk.role == .data {
            let srcURL = src.appendingPathComponent(srcDisk.path)
            let dstDisk = dstCfg.disks[i]   // 顺序保留
            let dstURL = result.targetBundle.appendingPathComponent(dstDisk.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dstURL.path))
            XCTAssertEqual(try sha256(of: srcURL), try sha256(of: dstURL),
                           "数据盘内容应一致")
        }
    }

    // MARK: - 5. keepMACAddresses=true 保留 MAC

    func testCloneKeepsMACWhenFlagSet() throws {
        let (src, srcCfg) = try makeFixtureBundle(displayName: "MacKeep",
                                                  guestOS: .linux,
                                                  engine: .vz)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "MacKeepClone", keepMACAddresses: true)
        )

        let dstCfg = try BundleIO.load(from: result.targetBundle)
        XCTAssertEqual(dstCfg.networks.count, srcCfg.networks.count)
        for (s, d) in zip(srcCfg.networks, dstCfg.networks) {
            XCTAssertEqual(s.macAddress, d.macAddress, "keepMAC=true 时 MAC 不变")
        }
    }

    // MARK: - 6. 默认重生 MAC

    func testCloneRegeneratesMACDefault() throws {
        let (src, srcCfg) = try makeFixtureBundle(displayName: "MacGen",
                                                  guestOS: .linux,
                                                  engine: .vz)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "MacGenClone")
        )

        let dstCfg = try BundleIO.load(from: result.targetBundle)
        XCTAssertEqual(dstCfg.networks.count, srcCfg.networks.count)
        for (s, d) in zip(srcCfg.networks, dstCfg.networks) {
            XCTAssertNotEqual(s.macAddress, d.macAddress, "默认应重生 MAC")
            // 校验仍是合法 locally-administered MAC
            XCTAssertNoThrow(try MACAddressGenerator.validate(d.macAddress))
        }
    }

    // MARK: - 7. 默认不带 snapshots

    func testCloneSkipsSnapshotsByDefault() throws {
        let (src, _) = try makeFixtureBundle(displayName: "SnapSkip",
                                              guestOS: .linux,
                                              engine: .vz,
                                              includeSnapshot: true)
        // 源里有 snapshot
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: BundleLayout.snapshotsDir(src).path))

        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "SnapSkipClone")
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BundleLayout.snapshotsDir(result.targetBundle).path),
            "默认不带 snapshots, 目标无 snapshots/ 目录")
    }

    // MARK: - 8. includeSnapshots=true 带 snapshots

    func testCloneIncludesSnapshotsWhenFlagSet() throws {
        let (src, _) = try makeFixtureBundle(displayName: "SnapIncl",
                                              guestOS: .linux,
                                              engine: .vz,
                                              includeSnapshot: true)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "SnapInclClone", includeSnapshots: true)
        )

        let srcSnapMeta = BundleLayout.snapshotDir(src, name: "test-snap")
                            .appendingPathComponent("meta.json")
        let dstSnapMeta = BundleLayout.snapshotDir(result.targetBundle, name: "test-snap")
                            .appendingPathComponent("meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstSnapMeta.path))
        XCTAssertEqual(try sha256(of: srcSnapMeta), try sha256(of: dstSnapMeta))
    }

    // MARK: - 9. 目标已存在 → 抛错

    func testCloneTargetExistsThrows() throws {
        let (src, _) = try makeFixtureBundle(displayName: "TargExists",
                                              guestOS: .linux,
                                              engine: .vz)
        // 预创建一个同名目标
        let target = tmpRoot.appendingPathComponent("Existing.hvmz", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        XCTAssertThrowsError(try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "Existing")
        )) { err in
            guard case HVMError.bundle(.alreadyExists) = err else {
                XCTFail("应抛 .bundle(.alreadyExists), 实抛 \(err)")
                return
            }
        }
        // 源不被破坏
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: BundleLayout.configURL(src).path))
    }

    // MARK: - 10. 源 running (持有 .runtime lock) → 抛错

    func testCloneRunningSourceThrows() throws {
        let (src, _) = try makeFixtureBundle(displayName: "Running",
                                              guestOS: .linux,
                                              engine: .vz)
        // 模拟源 VM 运行中: 持 .runtime lock
        let runningLock = try BundleLock(bundleURL: src, mode: .runtime)
        defer { runningLock.release() }

        XCTAssertThrowsError(try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "RunningClone")
        )) { err in
            guard case HVMError.bundle(.busy) = err else {
                XCTFail("应抛 .bundle(.busy), 实抛 \(err)")
                return
            }
        }
        // 目标不应被创建
        let target = tmpRoot.appendingPathComponent("RunningClone.hvmz", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - 11. 失败时清理 partial

    func testCloneCleansPartialOnFailure() throws {
        let (src, srcCfg) = try makeFixtureBundle(displayName: "PartialFail",
                                                  guestOS: .linux,
                                                  engine: .vz,
                                                  numDataDisks: 1)
        // 故意删一块数据盘, 让 clone 中途 cloneFile fail
        let dataDisk = srcCfg.disks.first { $0.role == .data }!
        try FileManager.default.removeItem(at: src.appendingPathComponent(dataDisk.path))

        XCTAssertThrowsError(try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "PartialClone")
        )) { err in
            // 应抛 storage.ioError (cloneFile 找不到源)
            guard case HVMError.storage(.ioError) = err else {
                XCTFail("应抛 .storage(.ioError), 实抛 \(err)")
                return
            }
        }
        // 目标应被完整清掉, 不留 partial
        let target = tmpRoot.appendingPathComponent("PartialClone.hvmz", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "失败必须清掉 partial 目标")
    }

    // MARK: - 12. schema 版本保留

    func testCloneYAMLSchemaPreserved() throws {
        let (src, _) = try makeFixtureBundle(displayName: "Schema",
                                              guestOS: .linux,
                                              engine: .vz)
        let result = try CloneManager.clone(
            sourceBundle: src,
            options: .init(newDisplayName: "SchemaClone")
        )

        let dstCfg = try BundleIO.load(from: result.targetBundle)
        XCTAssertEqual(dstCfg.schemaVersion, VMConfig.currentSchemaVersion,
                       "目标 schemaVersion 应等于当前")
    }
}
