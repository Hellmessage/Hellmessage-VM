// HVMBundleTests/VMConfigCodableTests.swift
// VMConfig + 关联类型的 Codable round-trip + 已知 schemaVersion 兼容.

import XCTest
@testable import HVMBundle

final class VMConfigCodableTests: XCTestCase {

    func testLinuxConfigRoundTrip() throws {
        let original = VMConfig(
            displayName: "ubuntu",
            guestOS: .linux,
            cpuCount: 4,
            memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 32)],
            networks: [NetworkSpec(mode: .nat, macAddress: "02:11:22:33:44:55")],
            installerISO: "/Users/me/ubuntu.iso",
            bootFromDiskOnly: false,
            macOS: nil,
            linux: LinuxSpec(rosettaShare: false)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfig.self, from: data)
        XCTAssertEqual(decoded.displayName, original.displayName)
        XCTAssertEqual(decoded.guestOS, original.guestOS)
        XCTAssertEqual(decoded.disks, original.disks)
        XCTAssertEqual(decoded.networks, original.networks)
        XCTAssertEqual(decoded.installerISO, original.installerISO)
        XCTAssertEqual(decoded.bootFromDiskOnly, original.bootFromDiskOnly)
        XCTAssertEqual(decoded.linux, original.linux)
        XCTAssertEqual(decoded.schemaVersion, VMConfig.currentSchemaVersion)
    }

    func testMacOSConfigRoundTrip() throws {
        let original = VMConfig(
            displayName: "mac1",
            guestOS: .macOS,
            cpuCount: 4,
            memoryMiB: 8192,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 80)],
            networks: [NetworkSpec(mode: .nat, macAddress: "02:aa:bb:cc:dd:ee")],
            installerISO: nil,
            bootFromDiskOnly: false,
            macOS: MacOSSpec(ipsw: "/Users/me/macOS.ipsw", autoInstalled: false),
            linux: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VMConfig.self, from: data)
        XCTAssertEqual(decoded.macOS, original.macOS)
        XCTAssertEqual(decoded.guestOS, .macOS)
    }

    func testNetworkModeNATCoding() throws {
        let nat = NetworkSpec(mode: .nat, macAddress: "02:00:00:00:00:01")
        let data = try JSONEncoder().encode(nat)
        let decoded = try JSONDecoder().decode(NetworkSpec.self, from: data)
        XCTAssertEqual(decoded, nat)
    }

    func testNetworkModeBridgedCoding() throws {
        let br = NetworkSpec(mode: .bridged(interface: "en0"), macAddress: "02:00:00:00:00:01")
        let data = try JSONEncoder().encode(br)
        let decoded = try JSONDecoder().decode(NetworkSpec.self, from: data)
        XCTAssertEqual(decoded, br)
    }

    /// schemaVersion 字段稳定: 编码后 JSON 里能找到, 数值 = currentSchemaVersion
    func testSchemaVersionPresentInJSON() throws {
        let cfg = VMConfig(
            displayName: "x",
            guestOS: .linux,
            cpuCount: 1,
            memoryMiB: 256,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 1)]
        )
        let data = try JSONEncoder().encode(cfg)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, VMConfig.currentSchemaVersion)
    }

    // MARK: - engine 字段 (v1 兼容 + 新 case)

    /// v1 老 config.json 没有 engine 字段, decode 出来必须默认 .vz
    /// (实现走 init(from:) 里的 decodeIfPresent ?? .vz)
    func testEngineDefaultsToVZ_v1Compat() throws {
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "id": "00000000-0000-0000-0000-000000000001",
          "createdAt": "2025-01-01T00:00:00Z",
          "displayName": "legacy",
          "guestOS": "linux",
          "cpuCount": 2,
          "memoryMiB": 2048,
          "disks": [{"role":"main","path":"disks/main.img","sizeGiB":16,"readOnly":false}],
          "networks": [],
          "bootFromDiskOnly": false
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cfg = try decoder.decode(VMConfig.self, from: legacyJSON)
        XCTAssertEqual(cfg.engine, .vz, "缺 engine 字段必须兜底 .vz, 否则 v1 老 bundle 会破")
    }

    /// 显式 engine=qemu 能正常 round-trip
    func testEngineQemuRoundTrip() throws {
        let cfg = VMConfig(
            displayName: "linux-qemu",
            guestOS: .linux,
            engine: .qemu,
            cpuCount: 4,
            memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 32)],
            linux: LinuxSpec()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cfg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfig.self, from: data)
        XCTAssertEqual(decoded.engine, .qemu)
    }

    // MARK: - Windows guest

    func testWindowsConfigRoundTrip() throws {
        let original = VMConfig(
            displayName: "win11",
            guestOS: .windows,
            engine: .qemu,
            cpuCount: 4,
            memoryMiB: 8192,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 64)],
            networks: [NetworkSpec(mode: .nat, macAddress: "02:de:ad:be:ef:01")],
            installerISO: "/Users/me/win11-arm64.iso",
            bootFromDiskOnly: false,
            windows: WindowsSpec(secureBoot: true, tpmEnabled: true)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VMConfig.self, from: data)
        XCTAssertEqual(decoded.guestOS, .windows)
        XCTAssertEqual(decoded.engine, .qemu)
        XCTAssertEqual(decoded.windows, WindowsSpec(secureBoot: true, tpmEnabled: true))
    }

    /// guestOS=windows 的字符串表示稳定 (UI/CLI 不会因 enum case 改名而坏)
    func testGuestOSWindowsRawValue() {
        XCTAssertEqual(GuestOSType.windows.rawValue, "windows")
    }

    // MARK: - validate(): engine ↔ guestOS 组合约束

    /// macOS guest + engine=qemu 必须报错 (VZMacOSInstaller 路径, QEMU 跑不了)
    func testValidateRejects_macOS_with_qemu() {
        let cfg = VMConfig(
            displayName: "bad",
            guestOS: .macOS,
            engine: .qemu,
            cpuCount: 4,
            memoryMiB: 8192,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 80)]
        )
        XCTAssertThrowsError(try cfg.validate())
    }

    /// Windows guest + engine=vz 必须报错 (VZ 无 TPM)
    func testValidateRejects_windows_with_vz() {
        let cfg = VMConfig(
            displayName: "bad",
            guestOS: .windows,
            engine: .vz,
            cpuCount: 4,
            memoryMiB: 8192,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 64)]
        )
        XCTAssertThrowsError(try cfg.validate())
    }

    /// 合法组合: macOS+vz / linux+vz / linux+qemu / windows+qemu 都不报错
    func testValidateAccepts_all_legal_combos() throws {
        let combos: [(GuestOSType, Engine)] = [
            (.macOS, .vz),
            (.linux, .vz),
            (.linux, .qemu),
            (.windows, .qemu),
        ]
        for (os, engine) in combos {
            let cfg = VMConfig(
                displayName: "ok",
                guestOS: os,
                engine: engine,
                cpuCount: 1,
                memoryMiB: 512,
                disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 1)]
            )
            XCTAssertNoThrow(try cfg.validate(), "合法组合 (\(os), \(engine)) 不应报错")
        }
    }
}
