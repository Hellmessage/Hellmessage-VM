// HVMQemu/QemuScreenshot.swift
// 高层封装: QmpClient.screendump → 读 PPM → CGImage → optional downscale → PNG bytes.
// 输出形态对齐 VZ 路径的 ScreenCapture.capturePNG 结果, 调用方 (QemuHostState) 直接复用.

import Foundation
import CoreGraphics
import CryptoKit

public enum QemuScreenshot {

    public struct Result: Sendable {
        public let pngData: Data
        public let widthPx: Int    // PNG 实际像素 (downscale 后, 与 VZ ScreenCapture 行为一致)
        public let heightPx: Int
        public let sha256: String  // PNG bytes 的 sha256, hex 小写

        public init(pngData: Data, widthPx: Int, heightPx: Int, sha256: String) {
            self.pngData = pngData
            self.widthPx = widthPx
            self.heightPx = heightPx
            self.sha256 = sha256
        }
    }

    public enum Error: Swift.Error, Sendable {
        case screendumpFailed(reason: String)
        case ppmParseFailed(reason: String)
        case readFailed(reason: String)
        case pngEncodeFailed
    }

    /// 截屏: QMP screendump → PPM → CGImage → PNG (可缩放).
    /// tempDir: 通常 BundleLayout.logsDir 或 HVMPaths.runDir; 调用方负责存在.
    /// maxEdge: nil 不缩放; >0 等比缩到最长边为该值 (Claude API 1568, OCR 不缩).
    public static func capture(
        via client: QmpClient,
        tempDir: URL,
        maxEdge: Int? = nil
    ) async throws -> Result {
        // 1. 写到 tempDir/<uuid>.ppm
        let ppmURL = tempDir.appendingPathComponent("hvm-shot-\(UUID().uuidString.prefix(8)).ppm")
        // env HVM_DEBUG_KEEP_PPM=1 时不删, 给倾斜 / stride 类 bug 排查 (打日志看 ppm 路径).
        let keepPPM = ProcessInfo.processInfo.environment["HVM_DEBUG_KEEP_PPM"] == "1"
        defer {
            if keepPPM {
                fputs("[QemuScreenshot] kept PPM at \(ppmURL.path)\n", stderr)
            } else {
                try? FileManager.default.removeItem(at: ppmURL)
            }
        }

        do {
            try await client.screendump(filename: ppmURL.path)
        } catch {
            throw Error.screendumpFailed(reason: "\(error)")
        }

        // 2. 读 PPM bytes
        let ppmData: Data
        do {
            ppmData = try Data(contentsOf: ppmURL)
        } catch {
            throw Error.readFailed(reason: "\(error)")
        }

        // 3. parse → CGImage (原分辨率)
        let cgImage: CGImage
        do {
            cgImage = try PPMReader.decode(ppmData)
        } catch {
            throw Error.ppmParseFailed(reason: "\(error)")
        }
        // 4. optional downscale
        let finalImage: CGImage
        if let maxEdge {
            finalImage = PPMReader.downscale(cgImage, maxEdge: maxEdge)
        } else {
            finalImage = cgImage
        }

        // 5. PNG encode
        guard let pngData = PPMReader.encodePNG(finalImage) else {
            throw Error.pngEncodeFailed
        }

        // 6. sha256
        let hex = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()

        // VZ 行为: 返回 PNG 实际像素 (downscale 后), 不是原始 guest 分辨率
        return Result(pngData: pngData, widthPx: finalImage.width, heightPx: finalImage.height, sha256: hex)
    }
}
