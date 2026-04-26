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
}
