// HVMCoreTests/HVMErrorTests.swift
// HVMError userFacing 映射 round-trip 测试; ErrorCodes 字符串稳定性.

import XCTest
@testable import HVMCore

final class HVMErrorTests: XCTestCase {

    func testUserFacingMessageNonEmpty() {
        let cases: [HVMError] = [
            .bundle(.notFound(path: "/x")),
            .bundle(.busy(pid: 0, holderMode: "runtime")),
            .bundle(.invalidSchema(version: 99, expected: 1)),
            .bundle(.parseFailed(reason: "x", path: "/x")),
            .bundle(.primaryDiskMissing(path: "/x")),
            .bundle(.corruptAuxiliary(reason: "x")),
            .bundle(.writeFailed(reason: "x", path: "/x")),
            .bundle(.outsideSandbox(requestedPath: "/x")),
            .bundle(.alreadyExists(path: "/x")),
            .bundle(.lockFailed(reason: "x")),
            .storage(.diskAlreadyExists(path: "/x")),
            .storage(.creationFailed(errno: 1, path: "/x")),
            .storage(.ioError(errno: 1, path: "/x")),
            .storage(.shrinkNotSupported(currentBytes: 1, requestedBytes: 2)),
            .storage(.isoMissing(path: "/x")),
            .storage(.isoSizeSuspicious(bytes: 0)),
            .storage(.cloneFailed(errno: 1)),
            .storage(.volumeSpaceInsufficient(requiredBytes: 1, availableBytes: 0)),
            .backend(.configInvalid(field: "x", reason: "x")),
            .backend(.cpuOutOfRange(requested: 0, min: 1, max: 16)),
            .backend(.memoryOutOfRange(requestedMiB: 0, minMiB: 256, maxMiB: 65536)),
            .backend(.diskNotFound(path: "/x")),
            .backend(.diskBusy(path: "/x")),
            .backend(.unsupportedGuestOS(raw: "windows")),
            .backend(.rosettaUnavailable),
            .backend(.bridgedNotEntitled),
            .backend(.ipswInvalid(reason: "x")),
            .backend(.invalidTransition(from: "stopped", to: "stopping")),
            .backend(.vzInternal(description: "x")),
            .install(.ipswNotFound(path: "/x")),
            .install(.ipswUnsupported(reason: "x")),
            .install(.ipswDownloadFailed(reason: "x")),
            .install(.auxiliaryCreationFailed(reason: "x")),
            .install(.diskSpaceInsufficient(requiredBytes: 1, availableBytes: 0)),
            .install(.installerFailed(reason: "x")),
            .install(.rosettaNotInstalled),
            .install(.isoNotFound(path: "/x")),
            .net(.bridgedNotEntitled),
            .net(.bridgedInterfaceNotFound(requested: "en0", available: ["en1"])),
            .net(.macInvalid("x")),
            .net(.macNotLocallyAdministered("x")),
            .ipc(.socketNotFound(path: "/x")),
            .ipc(.connectionRefused(path: "/x")),
            .ipc(.protocolMismatch(expected: 1, got: 2)),
            .ipc(.readFailed(reason: "x")),
            .ipc(.writeFailed(reason: "x")),
            .ipc(.decodeFailed(reason: "x")),
            .ipc(.remoteError(code: "x", message: "x")),
            .ipc(.timedOut),
            .ipc(.serverBindFailed(path: "/x", errno: 1)),
            .config(.missingField(name: "x")),
            .config(.invalidEnum(field: "x", raw: "x", allowed: ["a", "b"])),
            .config(.invalidRange(field: "x", value: "x", range: "1..10")),
            .config(.duplicateRole(role: "main")),
        ]
        for e in cases {
            let uf = e.userFacing
            XCTAssertFalse(uf.code.isEmpty, "\(e) 的 code 不应为空")
            XCTAssertFalse(uf.message.isEmpty, "\(e) 的 message 不应为空")
        }
    }

    /// userFacing 是 Codable, 跨 IPC 序列化要稳定
    func testUserFacingCodableRoundTrip() throws {
        let uf = UserFacingError(
            code: "bundle.busy",
            message: "Bundle 被占用",
            details: ["pid": "1234"],
            hint: "stop 一下"
        )
        let data = try JSONEncoder().encode(uf)
        let decoded = try JSONDecoder().decode(UserFacingError.self, from: data)
        XCTAssertEqual(uf, decoded)
    }
}
