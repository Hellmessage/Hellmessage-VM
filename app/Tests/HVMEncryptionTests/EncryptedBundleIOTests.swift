// HVMEncryptionTests/EncryptedBundleIOTests.swift
// 路由层 round-trip + 跨机器 portable 闭环 + 错密码 + scheme detect.

import XCTest
import CryptoKit
@testable import HVMEncryption
@testable import HVMBundle
@testable import HVMCore

final class EncryptedBundleIOTests: XCTestCase {

    private var parentDir: URL!
    /// 跟踪本测试创建的 sparsebundle 挂载, tearDown 兜底卸
    private var attachedMountpoints: Set<URL> = []

    override func setUpWithError() throws {
        // /tmp 短路径 (sparsebundle attach 内 socket 路径预算)
        let uuid8 = String(UUID().uuidString.prefix(8))
        parentDir = URL(fileURLWithPath: "/tmp/hvm-ebio-\(uuid8)")
        try FileManager.default.createDirectory(at: parentDir,
                                                 withIntermediateDirectories: true)
        attachedMountpoints = []
    }

    override func tearDownWithError() throws {
        // 兜底: 卸所有挂载
        let entries = (try? SparsebundleTool.info()) ?? []
        for entry in entries {
            guard let mp = entry.mountpoint else { continue }
            let mountURL = URL(fileURLWithPath: mp).standardizedFileURL
            // 仅卸本测试的 (在 attachedMountpoints 或 mountsRoot 下)
            if attachedMountpoints.contains(mountURL)
                || mountURL.path.hasPrefix(HVMPaths.mountsRoot.path) {
                try? SparsebundleTool.detach(mountpoint: mountURL, force: true)
            }
        }
        if let p = parentDir { try? FileManager.default.removeItem(at: p) }
    }

    private func makeBaseConfig(displayName: String,
                                 engine: Engine = .vz) -> VMConfig {
        VMConfig(
            displayName: displayName,
            guestOS: engine == .vz ? .linux : .linux,
            engine: engine,
            cpuCount: 2,
            memoryMiB: 2048,
            disks: [DiskSpec(role: .main,
                              path: engine == .vz ? "disks/os.img" : "disks/os.qcow2",
                              sizeGiB: 1,
                              format: engine == .vz ? .raw : .qcow2)],
            networks: [],
            linux: LinuxSpec()
        )
    }

    // MARK: - 1. VZ 路径 round-trip

    func testVZCreateThenUnlockRoundTrip() throws {
        let config = makeBaseConfig(displayName: "VZTest", engine: .vz)
        let pw = "secret-pass-vz"

        // === 创建 ===
        let createHandle = try EncryptedBundleIO.create(
            parentDir: parentDir,
            displayName: "VZTest",
            password: pw,
            baseConfig: config,
            scheme: .vzSparsebundle,
            sparsebundleSizeBytes: 50 * 1024 * 1024
        )
        if let mp = createHandle.mountpoint {
            attachedMountpoints.insert(mp.standardizedFileURL)
        }

        XCTAssertNotNil(createHandle.sparsebundleURL)
        XCTAssertNotNil(createHandle.mountpoint)
        XCTAssertNil(createHandle.qemuSubKeys, "VZ 路径不返子 keys")
        XCTAssertTrue(createHandle.bundleURL.path.contains(".hvmz"))

        // 在 mountpoint 内的 bundle 应已有 config.yaml
        let configURL = BundleLayout.configURL(createHandle.bundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path),
                      "VZ 路径 mountpoint 内应有 config.yaml")

        // routing JSON 已写
        XCTAssertTrue(FileManager.default.fileExists(atPath: createHandle.routingJSONURL.path))

        // 模拟"调用方在 close 前创建了主盘" (实际生产: CreateVMDialog 调 DiskFactory.create)
        // 不创建主盘 unlock 时 BundleIO.load 会抛 .primaryDiskMissing.
        let fakeDisk = createHandle.bundleURL.appendingPathComponent("disks/os.img")
        try Data().write(to: fakeDisk)

        let sparsebundleURL = createHandle.sparsebundleURL!
        try createHandle.close()
        attachedMountpoints.remove(createHandle.mountpoint!.standardizedFileURL)

        // === 解锁 (跨"会话"模拟) ===
        let unlockHandle = try EncryptedBundleIO.unlock(bundlePath: sparsebundleURL,
                                                         password: pw)
        if let mp = unlockHandle.mountpoint {
            attachedMountpoints.insert(mp.standardizedFileURL)
        }
        XCTAssertEqual(unlockHandle.scheme, .vzSparsebundle)
        XCTAssertEqual(unlockHandle.config.displayName, "VZTest")
        XCTAssertEqual(unlockHandle.config.id, config.id)
        XCTAssertEqual(unlockHandle.config.engine, .vz)
        try unlockHandle.close()
        attachedMountpoints.remove(unlockHandle.mountpoint!.standardizedFileURL)
    }

    // MARK: - 2. QEMU 路径 round-trip

    func testQemuCreateThenUnlockRoundTrip() throws {
        let config = makeBaseConfig(displayName: "QemuTest", engine: .qemu)
        let pw = "secret-pass-qemu"

        // === 创建 ===
        let createHandle = try EncryptedBundleIO.create(
            parentDir: parentDir,
            displayName: "QemuTest",
            password: pw,
            baseConfig: config,
            scheme: .qemuPerfile
        )

        XCTAssertNil(createHandle.sparsebundleURL)
        XCTAssertNil(createHandle.mountpoint)
        XCTAssertNotNil(createHandle.qemuSubKeys)
        XCTAssertEqual(createHandle.bundleURL.lastPathComponent, "QemuTest.hvmz")

        // config.yaml.enc 应已写, 明文 config.yaml 应不存在
        XCTAssertTrue(EncryptedConfigIO.isEncrypted(at: createHandle.bundleURL))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BundleLayout.configURL(createHandle.bundleURL).path))

        // routing JSON 在 meta/ 下
        XCTAssertTrue(FileManager.default.fileExists(atPath: createHandle.routingJSONURL.path))
        let bundleURL = createHandle.bundleURL
        try createHandle.close()

        // === 解锁 ===
        let unlockHandle = try EncryptedBundleIO.unlock(bundlePath: bundleURL,
                                                         password: pw)
        XCTAssertEqual(unlockHandle.scheme, .qemuPerfile)
        XCTAssertEqual(unlockHandle.config.displayName, "QemuTest")
        XCTAssertEqual(unlockHandle.config.id, config.id)
        XCTAssertEqual(unlockHandle.config.engine, .qemu)
        XCTAssertNotNil(unlockHandle.qemuSubKeys)
        try unlockHandle.close()
    }

    // MARK: - 3. 错密码 unlock 失败

    func testUnlockWithWrongPasswordFailsVZ() throws {
        let config = makeBaseConfig(displayName: "WrongPwVZ", engine: .vz)
        let createHandle = try EncryptedBundleIO.create(
            parentDir: parentDir, displayName: "WrongPwVZ",
            password: "real-pw", baseConfig: config,
            scheme: .vzSparsebundle, sparsebundleSizeBytes: 50 * 1024 * 1024
        )
        if let mp = createHandle.mountpoint {
            attachedMountpoints.insert(mp.standardizedFileURL)
        }
        let sparsebundleURL = createHandle.sparsebundleURL!
        try createHandle.close()
        attachedMountpoints.remove(createHandle.mountpoint!.standardizedFileURL)

        XCTAssertThrowsError(try EncryptedBundleIO.unlock(
            bundlePath: sparsebundleURL,
            password: "wrong-pw"
        )) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("应抛 .wrongPassword, 实抛 \(err)")
                return
            }
        }
    }

    func testUnlockWithWrongPasswordFailsQemu() throws {
        let config = makeBaseConfig(displayName: "WrongPwQemu", engine: .qemu)
        let createHandle = try EncryptedBundleIO.create(
            parentDir: parentDir, displayName: "WrongPwQemu",
            password: "real-pw-qemu", baseConfig: config,
            scheme: .qemuPerfile
        )
        let bundleURL = createHandle.bundleURL
        try createHandle.close()

        XCTAssertThrowsError(try EncryptedBundleIO.unlock(
            bundlePath: bundleURL,
            password: "wrong-pw"
        )) { err in
            guard case HVMError.encryption(.wrongPassword) = err else {
                XCTFail("应抛 .wrongPassword, 实抛 \(err)")
                return
            }
        }
    }

    // MARK: - 4. detectScheme

    func testDetectSchemeVZ() throws {
        let config = makeBaseConfig(displayName: "DetectVZ", engine: .vz)
        let handle = try EncryptedBundleIO.create(
            parentDir: parentDir, displayName: "DetectVZ", password: "pw",
            baseConfig: config, scheme: .vzSparsebundle,
            sparsebundleSizeBytes: 50 * 1024 * 1024
        )
        if let mp = handle.mountpoint {
            attachedMountpoints.insert(mp.standardizedFileURL)
        }
        let sparsebundleURL = handle.sparsebundleURL!
        try handle.close()
        attachedMountpoints.remove(handle.mountpoint!.standardizedFileURL)

        XCTAssertEqual(EncryptedBundleIO.detectScheme(at: sparsebundleURL), .vzSparsebundle)
        XCTAssertEqual(EncryptedBundleIO.detectScheme(at: parentDir,
                                                      displayName: "DetectVZ"),
                       .vzSparsebundle)
    }

    func testDetectSchemeQemu() throws {
        let config = makeBaseConfig(displayName: "DetectQemu", engine: .qemu)
        let handle = try EncryptedBundleIO.create(
            parentDir: parentDir, displayName: "DetectQemu", password: "pw",
            baseConfig: config, scheme: .qemuPerfile
        )
        let bundleURL = handle.bundleURL
        try handle.close()

        XCTAssertEqual(EncryptedBundleIO.detectScheme(at: bundleURL), .qemuPerfile)
    }

    func testDetectSchemeReturnsNilForPlaintext() throws {
        let plainBundle = parentDir.appendingPathComponent("Plain.hvmz", isDirectory: true)
        try FileManager.default.createDirectory(at: plainBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: BundleLayout.metaDir(plainBundle),
                                                  withIntermediateDirectories: true)
        XCTAssertNil(EncryptedBundleIO.detectScheme(at: plainBundle),
                     "明文 bundle 无 routing JSON, 不应识别为加密")
    }

    // MARK: - 5. 跨机器 portable: 模拟源机 → 目标机

    /// 跨机器 portable 闭环: 源机创建 + 关闭 → 复制 sparsebundle/.hvmz 到"目标机" → 用同密码解开
    func testCrossMachinePortabilityQemu() throws {
        let pw = "shared-secret-2026"
        let config = makeBaseConfig(displayName: "Portable", engine: .qemu)

        // 源机
        let sourceHandle = try EncryptedBundleIO.create(
            parentDir: parentDir, displayName: "Portable", password: pw,
            baseConfig: config, scheme: .qemuPerfile
        )
        try sourceHandle.close()

        // 模拟"复制到目标机": cp -R 整个 .hvmz 到另一目录
        let targetParent = parentDir.appendingPathComponent("target-machine")
        try FileManager.default.createDirectory(at: targetParent, withIntermediateDirectories: true)
        let sourceBundle = sourceHandle.bundleURL
        let targetBundle = targetParent.appendingPathComponent(sourceBundle.lastPathComponent,
                                                                 isDirectory: true)
        try FileManager.default.copyItem(at: sourceBundle, to: targetBundle)

        // 目标机用同密码解锁
        let targetHandle = try EncryptedBundleIO.unlock(bundlePath: targetBundle, password: pw)
        XCTAssertEqual(targetHandle.config.id, config.id, "跨机器 portable: VM ID 一致")
        XCTAssertEqual(targetHandle.config.displayName, "Portable")
        try targetHandle.close()
    }

    // MARK: - 6. RoutingMetadata snake_case 字段名稳定

    func testRoutingJSONSnakeCaseFieldNames() throws {
        let routing = RoutingMetadata(
            vmId: UUID(),
            scheme: .qemuPerfile,
            displayName: "Test",
            kdfSalt: Data(repeating: 0xAA, count: 16)
        )
        let url = parentDir.appendingPathComponent("test-routing.json")
        try RoutingJSON.write(routing, to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        // 字段名稳定 — 改了等于破坏跨机器 portable / 老 routing JSON 不兼容
        XCTAssertTrue(raw.contains("\"vm_id\""), "应有 vm_id 字段")
        XCTAssertTrue(raw.contains("\"display_name\""), "应有 display_name 字段")
        XCTAssertTrue(raw.contains("\"kdf_algo\""), "应有 kdf_algo 字段")
        XCTAssertTrue(raw.contains("\"kdf_iterations\""), "应有 kdf_iterations 字段")
        XCTAssertTrue(raw.contains("\"kdf_salt\""), "应有 kdf_salt 字段")
        XCTAssertTrue(raw.contains("\"kdf_keylen\""), "应有 kdf_keylen 字段")
        XCTAssertTrue(raw.contains("\"encrypted_paths\""), "QEMU scheme 应有 encrypted_paths 字段")

        let read = try RoutingJSON.read(from: url)
        XCTAssertEqual(read, routing)
    }

    func testRoutingJSONOmitsEncryptedPathsForVZ() throws {
        let routing = RoutingMetadata(
            vmId: UUID(),
            scheme: .vzSparsebundle,
            displayName: "VZRouting",
            kdfSalt: Data(repeating: 0xBB, count: 16)
        )
        let url = parentDir.appendingPathComponent("vz-routing.json")
        try RoutingJSON.write(routing, to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("\"encrypted_paths\""),
                       "VZ scheme 整 sparsebundle 加密, 不应列分项 encrypted_paths")
    }
}
