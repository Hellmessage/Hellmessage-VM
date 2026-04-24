// HVMCore 最小烟雾测试, 保证 swift test 管线通
// M1+ 各模块补真正的单元测试

import XCTest
@testable import HVMCore

final class SmokeTests: XCTestCase {
    func testVersionStringNotEmpty() {
        XCTAssertFalse(HVMVersion.displayString.isEmpty)
    }

    func testLoggerSubsystem() {
        XCTAssertEqual(HVMLog.subsystem, "com.hellmessage.vm")
    }

    func testErrorCodesAreUnique() {
        let codes = [
            HVMErrorCode.bundleBusy.rawValue,
            HVMErrorCode.storageIOError.rawValue,
            HVMErrorCode.backendVZInternal.rawValue,
            HVMErrorCode.ipcTimedOut.rawValue,
        ]
        XCTAssertEqual(codes.count, Set(codes).count, "ErrorCodes 中不应出现重复 raw value")
    }
}
