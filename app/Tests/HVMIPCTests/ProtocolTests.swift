// HVMIPCTests/ProtocolTests.swift

import XCTest
@testable import HVMIPC

final class ProtocolTests: XCTestCase {

    func testRequestRoundTripWithVersion() throws {
        let req = IPCRequest(op: "status", args: ["foo": "bar"])
        XCTAssertEqual(req.protoVersion, IPCProtocol.version)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertEqual(decoded.op, "status")
        XCTAssertEqual(decoded.args, ["foo": "bar"])
        XCTAssertEqual(decoded.protoVersion, IPCProtocol.version)
    }

    /// 老客户端 (没 protoVersion 字段的 JSON) 也能解码 → 服务端会视作 legacy
    func testLegacyClientRequestDecodes() throws {
        let json = #"{"id":"x","op":"status","args":{}}"#
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        XCTAssertNil(decoded.protoVersion)
        XCTAssertEqual(decoded.op, "status")
    }

    /// 未知字段 (新客户端到老服务端) 也不会解码失败
    func testFutureFieldIgnored() throws {
        let json = #"{"id":"x","op":"status","args":{},"protoVersion":1,"futureField":42}"#
        let data = json.data(using: .utf8)!
        XCTAssertNoThrow(try JSONDecoder().decode(IPCRequest.self, from: data))
    }

    func testResponseSuccess() throws {
        let r = IPCResponse.success(id: "abc", data: ["k": "v"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.data?["k"], "v")
        XCTAssertNil(r.error)
        let bytes = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: bytes)
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertTrue(decoded.ok)
    }

    func testResponseFailure() throws {
        let r = IPCResponse.failure(id: "x", code: "ipc.protocol_mismatch",
                                    message: "v mismatch", details: ["client": "2", "server": "1"])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "ipc.protocol_mismatch")
        XCTAssertEqual(r.error?.details["client"], "2")
    }
}
