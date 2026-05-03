// HDPProtocolFuzzTests.swift
// HDP 协议解析层的 malformed input 覆盖. 协议层走 unix domain socket, 同机进程能投毒,
// 解析必须对截断 / 错误版本 / 越界 payload_len / 未知 msg type 鲁棒.
//
// 注: 当前 HDP.Header.decode / Payload.decode 用 "返回 nil" 表达失败而不是 throw,
// 测试就以 nil 作为契约. 若未来加 HDPError throw 路径, 测试要同步升级断言.

import XCTest
@testable import HVMDisplayQemu

final class HDPProtocolFuzzTests: XCTestCase {

    // MARK: - Header decode 边界

    func testHeaderTruncatedReturnsNil() {
        // 0..<8 byte 都是不完整 header
        for n in 0..<HDP.Header.byteSize {
            let truncated = Data(repeating: 0, count: n)
            XCTAssertNil(HDP.Header.decode(truncated),
                         "header 长度 \(n) 应解析失败 (期望 \(HDP.Header.byteSize))")
        }
    }

    func testHeaderExactSizeDecodes() {
        let h = HDP.Header(type: .hello, flags: [], payloadLen: 8)
        let decoded = HDP.Header.decode(h.encode())
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, HDP.MessageType.hello.rawValue)
        XCTAssertEqual(decoded?.payloadLen, 8)
    }

    func testHeaderExtraBytesIgnored() {
        // header 之后多 100 字节, decode 仍只取前 8 字节
        var raw = HDP.Header(type: .hello, flags: [], payloadLen: 8).encode()
        raw.append(Data(repeating: 0xAA, count: 100))
        let decoded = HDP.Header.decode(raw)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.payloadLen, 8)
    }

    /// 未知 msg type (例如 0xFFFE) 应能被 Header.decode 出来 (UInt16 raw),
    /// 但 MessageType(rawValue:) 应拒绝, 调用层据此抛 protocol error / GOODBYE.
    func testUnknownMessageTypeRawDecodesButEnumRejects() {
        let h = HDP.Header(type: 0xFFFE, flags: [], payloadLen: 0)
        let decoded = HDP.Header.decode(h.encode())
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, 0xFFFE)
        XCTAssertNil(HDP.MessageType(rawValue: 0xFFFE),
                     "未知 type 不应被 enum 接受 — 调用层应据此 GOODBYE.protocolError")
    }

    // MARK: - HELLO payload

    func testHelloTruncatedReturnsNil() {
        for n in 0..<HDP.Hello.byteSize {
            XCTAssertNil(HDP.Hello.decode(Data(repeating: 0, count: n)),
                         "HELLO payload 长度 \(n) 应解析失败")
        }
    }

    func testHelloRoundTrip() {
        let original = HDP.Hello(protoVersion: HDP.protoVersion,
                                 capabilities: HDP.Capabilities.hostAdvertised)
        let decoded = HDP.Hello.decode(original.encode())
        XCTAssertEqual(decoded?.protoVersion, HDP.protoVersion)
        XCTAssertEqual(decoded?.capabilities.rawValue, HDP.Capabilities.hostAdvertised.rawValue)
    }

    /// peer 跨 major 版本 (例如 v2.x.x), host 应能识别并 GOODBYE.
    func testHelloMajorMismatchDetectable() {
        let peerV2 = (UInt32(2) << 16)  // 2.0.0
        let peerHello = HDP.Hello(protoVersion: peerV2, capabilities: [])
        let decoded = HDP.Hello.decode(peerHello.encode())
        XCTAssertNotNil(decoded)
        XCTAssertNotEqual(HDP.major(of: decoded!.protoVersion),
                          HDP.major(of: HDP.protoVersion),
                          "host major != peer major — 调用层应 GOODBYE.versionMismatch")
    }

    // MARK: - SurfaceNew payload

    func testSurfaceNewTruncatedReturnsNil() {
        for n in stride(from: 0, to: HDP.SurfaceNew.byteSize, by: 1) {
            XCTAssertNil(HDP.SurfaceNew.decode(Data(repeating: 0, count: n)),
                         "SurfaceNew payload 长度 \(n) 应解析失败 (期望 \(HDP.SurfaceNew.byteSize))")
        }
    }

    func testSurfaceNewRoundTrip() {
        let original = HDP.SurfaceNew(width: 1920, height: 1080,
                                       stride: 1920 * 4,
                                       format: HDP.PixelFormat.bgra8.rawValue,
                                       shmSize: 1920 * 1080 * 4)
        let decoded = HDP.SurfaceNew.decode(original.encode())
        XCTAssertEqual(decoded?.width, 1920)
        XCTAssertEqual(decoded?.height, 1080)
        XCTAssertEqual(decoded?.shmSize, 1920 * 1080 * 4)
    }

    // MARK: - SurfaceDamage payload

    func testSurfaceDamageTruncatedReturnsNil() {
        for n in 0..<HDP.SurfaceDamage.byteSize {
            XCTAssertNil(HDP.SurfaceDamage.decode(Data(repeating: 0, count: n)),
                         "SurfaceDamage payload 长度 \(n) 应解析失败")
        }
    }

    func testSurfaceDamageRoundTrip() {
        let original = HDP.SurfaceDamage(x: 100, y: 50, w: 200, h: 150)
        let decoded = HDP.SurfaceDamage.decode(original.encode())
        XCTAssertEqual(decoded?.x, 100)
        XCTAssertEqual(decoded?.y, 50)
        XCTAssertEqual(decoded?.w, 200)
        XCTAssertEqual(decoded?.h, 150)
    }

    // MARK: - 异常 payload_len 上界

    /// payload_len 字段是 UInt32, 理论上能表 4GB — host 必须有上限策略避免 OOM.
    /// 此测试只验证 decode 不 crash; 上限拒绝是 channel 层职责 (本 fuzz 不覆盖).
    func testHeaderHugePayloadLenDoesNotCrash() {
        let h = HDP.Header(type: .surfaceDamage, flags: [], payloadLen: UInt32.max)
        let decoded = HDP.Header.decode(h.encode())
        XCTAssertEqual(decoded?.payloadLen, UInt32.max)
    }

    // MARK: - flags 与 capability 字段

    func testHeaderFlagsRoundTrip() {
        let h = HDP.Header(type: .surfaceNew,
                           flags: [.hasFD, .urgent],
                           payloadLen: HDP.SurfaceNew.byteSize.uint32)
        let decoded = HDP.Header.decode(h.encode())
        XCTAssertEqual(decoded?.flags.contains(.hasFD), true)
        XCTAssertEqual(decoded?.flags.contains(.urgent), true)
    }

    func testCapabilitiesUnknownBitsPreserved() {
        // peer 带 host 不识别的 capability bit 0x80000000 — host 必须保留 raw 值
        // (否则 GOODBYE 时无法回传给对方诊断)
        let peerCap = HDP.Capabilities(rawValue: 0x80000007)
        let hello = HDP.Hello(protoVersion: HDP.protoVersion, capabilities: peerCap)
        let decoded = HDP.Hello.decode(hello.encode())
        XCTAssertEqual(decoded?.capabilities.rawValue, 0x80000007)
    }
}

// MARK: - 内部小 helper

private extension Int {
    var uint32: UInt32 { UInt32(self) }
}
