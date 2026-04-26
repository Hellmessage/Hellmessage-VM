// HVMQemuTests/PPMReaderTests.swift
// PPM (P6) 解析与编码 round-trip + 错误形态.

import XCTest
@testable import HVMQemu
import CoreGraphics

final class PPMReaderTests: XCTestCase {

    /// 拼一个合法 P6 PPM bytes: width×height 像素, 灰色填充.
    private func minimalP6(width: Int = 2, height: Int = 2) -> Data {
        var data = Data()
        data.append("P6\n".data(using: .ascii)!)
        data.append("\(width) \(height)\n".data(using: .ascii)!)
        data.append("255\n".data(using: .ascii)!)
        // 全灰 (128, 128, 128) 填满
        data.append(contentsOf: Array(repeating: UInt8(128), count: width * height * 3))
        return data
    }

    func testDecodeMinimalP6() throws {
        let data = minimalP6()
        let img = try PPMReader.decode(data)
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual(img.height, 2)
        XCTAssertEqual(img.bitsPerComponent, 8)
        XCTAssertEqual(img.bitsPerPixel, 24)
    }

    func testDecodeWithComments() throws {
        // PPM spec 允许在 header 任意位置插 # 注释行
        var data = Data()
        data.append("P6\n".data(using: .ascii)!)
        data.append("# Created by qemu screendump\n".data(using: .ascii)!)
        data.append("# Another line\n".data(using: .ascii)!)
        data.append("2 2\n255\n".data(using: .ascii)!)
        data.append(contentsOf: [0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
        let img = try PPMReader.decode(data)
        XCTAssertEqual(img.width, 2)
    }

    func testRejectNotP6() {
        let data = "P3\n2 2\n255\n0 0 0".data(using: .ascii)!
        XCTAssertThrowsError(try PPMReader.decode(data)) { error in
            guard case PPMReader.ParseError.notP6 = error else {
                return XCTFail("期望 .notP6, 实际 \(error)")
            }
        }
    }

    func testRejectMaxValOver255() {
        var data = Data()
        data.append("P6\n2 2\n65535\n".data(using: .ascii)!)
        // 16-bit 数据每像素 6 bytes, 但我们就放 12 个 0 (8-bit fake) 看是否 error 早抛在 maxval 检查
        data.append(contentsOf: Array(repeating: UInt8(0), count: 24))
        XCTAssertThrowsError(try PPMReader.decode(data)) { error in
            guard case PPMReader.ParseError.unsupportedMaxValue(65535) = error else {
                return XCTFail("期望 .unsupportedMaxValue(65535), 实际 \(error)")
            }
        }
    }

    func testRejectTruncated() {
        var data = Data()
        data.append("P6\n2 2\n255\n".data(using: .ascii)!)
        // 只放 3 个字节, 不够 12
        data.append(contentsOf: [0xFF, 0x00, 0x00])
        XCTAssertThrowsError(try PPMReader.decode(data)) { error in
            guard case PPMReader.ParseError.truncatedPixelData = error else {
                return XCTFail("期望 .truncatedPixelData, 实际 \(error)")
            }
        }
    }

    func testEncodePNGRoundTrip() throws {
        let data = minimalP6(width: 4, height: 4)
        let img = try PPMReader.decode(data)
        let png = PPMReader.encodePNG(img)
        XCTAssertNotNil(png)
        // PNG 头是 89 50 4E 47 0D 0A 1A 0A
        XCTAssertEqual(png?.first, 0x89)
        XCTAssertEqual(png?[1], 0x50)
        XCTAssertEqual(png?[2], 0x4E)
        XCTAssertEqual(png?[3], 0x47)
    }

    func testDownscaleKeepsAspect() throws {
        // 原图 100x50, downscale to maxEdge 25 → 应得 25x12 (不是 25x25)
        // 用一个稍大 PPM 验证
        var data = Data()
        data.append("P6\n100 50\n255\n".data(using: .ascii)!)
        data.append(contentsOf: Array(repeating: UInt8(128), count: 100 * 50 * 3))
        let img = try PPMReader.decode(data)
        let scaled = PPMReader.downscale(img, maxEdge: 25)
        XCTAssertEqual(scaled.width, 25)
        // 50/100 = 0.5, 25 * 0.5 = 12.5 → round 12 或 13
        XCTAssertTrue(scaled.height >= 12 && scaled.height <= 13)
    }

    func testDownscaleNoOpWhenSmaller() throws {
        let data = minimalP6()
        let img = try PPMReader.decode(data)
        // maxEdge=100, 原图 2x2, 不缩
        let scaled = PPMReader.downscale(img, maxEdge: 100)
        XCTAssertEqual(scaled.width, 2)
        XCTAssertEqual(scaled.height, 2)
    }
}
