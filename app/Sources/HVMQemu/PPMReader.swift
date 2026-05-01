// HVMQemu/PPMReader.swift
// PPM (P6, binary RGB) → CGImage. QEMU `screendump` 默认输出 P6.
//
// PPM P6 文件结构:
//   "P6\n"                                    magic
//   <可选 # 注释行, 任意数量>
//   "<width> <height>\n"                      尺寸
//   "<maxval>\n"                              通道最大值 (255 → 8-bit, 65535 → 16-bit)
//   <width * height * channels * bytes 二进制 RGB>
//
// QEMU 的 PPM 都是 maxval=255, 8-bit RGB; 我们只解码这一种以保持简单. 16-bit 不支持.

import Foundation
import CoreGraphics
import ImageIO

public enum PPMReader {

    public enum ParseError: Error, Sendable, Equatable {
        case notP6
        case malformedHeader(reason: String)
        case truncatedPixelData(expected: Int, got: Int)
        case unsupportedMaxValue(Int)   // QEMU 输出 8-bit; 16-bit (P6 maxval > 255) 不实现
        case cgImageCreationFailed
    }

    /// 解码 PPM P6 bytes → CGImage. 读 header 跳注释 + 二进制 RGB → CGContext → makeImage.
    /// 只读 PPM 头拿 width/height, 不解 binary pixel 数据. 用于 hvm-dbg display-info
    /// 验证 spice-vdagent dynamic resize 是否实际生效 (resize 前后两次 display-info
    /// 对比 width/height 是否变化), 不必传输完整 PNG.
    public static func readDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        var idx = 0
        guard data.count >= 3 else { throw ParseError.notP6 }
        guard data[0] == 0x50, data[1] == 0x36 else {       // 'P', '6'
            throw ParseError.notP6
        }
        idx = 2
        skipWhitespaceAndComments(data, &idx)
        let width = try readASCIIInt(data, &idx)
        skipWhitespaceAndComments(data, &idx)
        let height = try readASCIIInt(data, &idx)
        return (width, height)
    }

    public static func decode(_ data: Data) throws -> CGImage {
        var idx = 0

        // 1. magic "P6"
        guard data.count >= 3 else { throw ParseError.notP6 }
        guard data[0] == 0x50, data[1] == 0x36 else {           // 'P', '6'
            throw ParseError.notP6
        }
        idx = 2
        skipWhitespaceAndComments(data, &idx)

        // 2. width
        let width = try readASCIIInt(data, &idx)
        skipWhitespaceAndComments(data, &idx)

        // 3. height
        let height = try readASCIIInt(data, &idx)
        skipWhitespaceAndComments(data, &idx)

        // 4. maxval
        let maxval = try readASCIIInt(data, &idx)
        guard maxval == 255 else {
            throw ParseError.unsupportedMaxValue(maxval)
        }

        // 5. 单字节 whitespace 后是 binary 数据 (规范要求恰好 1 字节, 通常 \n)
        guard idx < data.count else {
            throw ParseError.malformedHeader(reason: "missing whitespace after maxval")
        }
        let sep = data[idx]
        guard sep == 0x0A || sep == 0x0D || sep == 0x20 || sep == 0x09 else {
            throw ParseError.malformedHeader(reason: "expected single whitespace, got byte 0x\(String(sep, radix: 16))")
        }
        idx += 1

        // 6. binary RGB
        // **关键**: QEMU virtio-gpu / viogpudo framebuffer 用 2-pixel alignment, 物理 width
        // 取 ceil(w/2)*2 (e.g. logical 839 → physical 840), 每行 stride = physical_w * 3
        // 字节. 但 QEMU screendump 在 PPM header 里写**逻辑 width** (839), 让 packed
        // assumption (stride = w*3) 漂移每行 3 字节, 累积成 hvm-dbg screenshot 输出图片
        // 倾斜的视觉效果. PPM spec 规定 stride = w*3 (no padding), 但 QEMU 这一路违反.
        // Fix: 用 (body_size / height) 推 actual stride, 每行只取前 width*3 字节, 重组
        // packed buffer 给 CGImage.
        let logicalRowBytes = width * 3
        let remaining = data.count - idx
        guard remaining >= logicalRowBytes * height else {
            throw ParseError.truncatedPixelData(expected: logicalRowBytes * height, got: remaining)
        }
        let actualStride = remaining / height
        let pixelData: Data
        if actualStride == logicalRowBytes {
            // 标准 packed PPM, 直接 slice
            pixelData = data.subdata(in: idx..<(idx + logicalRowBytes * height))
        } else if actualStride > logicalRowBytes {
            // 有 row padding (QEMU viogpudo / virtio-gpu): 逐行抽 width*3 字节重组 packed
            var repacked = Data(capacity: logicalRowBytes * height)
            for row in 0..<height {
                let rowStart = idx + row * actualStride
                repacked.append(data.subdata(in: rowStart..<(rowStart + logicalRowBytes)))
            }
            pixelData = repacked
        } else {
            throw ParseError.truncatedPixelData(expected: logicalRowBytes * height, got: remaining)
        }

        // 7. CGImage from RGB bytes (no alpha)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let provider = CGDataProvider(data: pixelData as CFData),
              let img = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: width * 3,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw ParseError.cgImageCreationFailed
        }
        return img
    }

    /// 把 CGImage 编码为 PNG bytes. 不依赖 AppKit, 用 ImageIO + ImageDestination.
    public static func encodePNG(_ image: CGImage) -> Data? {
        let dest = NSMutableData()
        let typeID = "public.png" as CFString   // kUTTypePNG, 不导 MobileCoreServices
        guard let imageDest = CGImageDestinationCreateWithData(dest, typeID, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(imageDest, image, nil)
        guard CGImageDestinationFinalize(imageDest) else { return nil }
        return dest as Data
    }

    /// 按最长边等比缩放 (与 ScreenCapture.downscale 等价); 短于 maxEdge 直接返原图.
    public static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxEdge else { return image }
        let ratio = CGFloat(maxEdge) / CGFloat(longest)
        let newW = max(1, Int((CGFloat(w) * ratio).rounded()))
        let newH = max(1, Int((CGFloat(h) * ratio).rounded()))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    // MARK: - 内部 byte parsing helpers

    private static func skipWhitespaceAndComments(_ data: Data, _ idx: inout Int) {
        while idx < data.count {
            let b = data[idx]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {  // space tab \n \r
                idx += 1
            } else if b == 0x23 {  // '#'
                while idx < data.count, data[idx] != 0x0A { idx += 1 }
            } else {
                return
            }
        }
    }

    private static func readASCIIInt(_ data: Data, _ idx: inout Int) throws -> Int {
        var s = ""
        while idx < data.count {
            let b = data[idx]
            if b >= 0x30 && b <= 0x39 {  // '0'-'9'
                s.append(Character(UnicodeScalar(b)))
                idx += 1
            } else {
                break
            }
        }
        guard let n = Int(s) else {
            throw ParseError.malformedHeader(reason: "expected ASCII int, got \"\(s)\"")
        }
        return n
    }
}
