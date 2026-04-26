// HVMNetTests/MACAddressTests.swift

import XCTest
@testable import HVMNet
@testable import HVMCore

final class MACAddressTests: XCTestCase {

    func testRandomFormat() {
        for _ in 0..<200 {
            let mac = MACAddressGenerator.random()
            // 6 组, 每组 2 hex
            let parts = mac.split(separator: ":")
            XCTAssertEqual(parts.count, 6, "mac \(mac) 不是 6 段")
            for p in parts {
                XCTAssertEqual(p.count, 2)
                XCTAssertNotNil(UInt8(p, radix: 16), "\(p) 不是 hex")
            }
            // 全小写
            XCTAssertEqual(mac, mac.lowercased())
        }
    }

    func testRandomIsLocallyAdministered() {
        for _ in 0..<200 {
            let mac = MACAddressGenerator.random()
            XCTAssertNoThrow(try MACAddressGenerator.validate(mac), "\(mac) 应通过校验")
        }
    }

    func testValidateRejectsMulticast() {
        // 第一字节最低位为 1 (multicast)
        XCTAssertThrowsError(try MACAddressGenerator.validate("01:00:00:00:00:00"))
    }

    func testValidateRejectsNonLocallyAdministered() {
        // U/L 位 = 0
        XCTAssertThrowsError(try MACAddressGenerator.validate("00:00:00:00:00:00"))
    }

    func testValidateRejectsBadFormat() {
        XCTAssertThrowsError(try MACAddressGenerator.validate("xx:yy:zz"))
        XCTAssertThrowsError(try MACAddressGenerator.validate("02-aa-bb-cc-dd-ee"))
        XCTAssertThrowsError(try MACAddressGenerator.validate(""))
    }
}
