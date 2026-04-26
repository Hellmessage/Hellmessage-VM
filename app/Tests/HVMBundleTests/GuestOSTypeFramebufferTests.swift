// HVMBundleTests/GuestOSTypeFramebufferTests.swift
// GuestOSType.defaultFramebufferSize 三处映射测试 (替代之前 4 处散落 switch).

import XCTest
@testable import HVMBundle

final class GuestOSTypeFramebufferTests: XCTestCase {

    func testLinuxIs1024x768() {
        let s = GuestOSType.linux.defaultFramebufferSize
        XCTAssertEqual(s.width, 1024)
        XCTAssertEqual(s.height, 768)
    }

    func testMacOSIs1920x1080() {
        let s = GuestOSType.macOS.defaultFramebufferSize
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
    }

    func testWindowsIs1920x1080() {
        // Win11 推荐最低分辨率, 与 macOS 同
        let s = GuestOSType.windows.defaultFramebufferSize
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
    }
}
