// HVMDisplay/OCREngine.swift
// 用 Vision framework (VNRecognizeTextRequest) 识别 frame buffer 里的文字.
// 纯本地推理, 不联网. 支持指定 region.
//
// 输出坐标: guest 像素左上原点 (而 Vision 原生是 0-1 normalized + 左下原点, 这里转完).

import AppKit
import Foundation
import HVMCore
import Vision

public enum OCREngine {
    public struct TextItem: Sendable, Codable {
        /// guest 像素 bbox (左上原点)
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let text: String
        public let confidence: Float

        public init(x: Int, y: Int, width: Int, height: Int, text: String, confidence: Float) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.text = text; self.confidence = confidence
        }

        public var bbox: [Int] { [x, y, x + width, y + height] }
        public var center: [Int] { [x + width / 2, y + height / 2] }
    }

    /// 对 PNG 数据做 OCR. 失败抛 backend.vz_internal.
    /// - Parameters:
    ///   - pngData: ScreenCapture 出来的 PNG 字节
    ///   - region: nil = 全屏; 否则 (x, y, width, height) 在 guest 像素坐标系裁剪
    @MainActor
    public static func recognize(pngData: Data, region: CGRect? = nil) throws -> [TextItem] {
        guard let img = NSImage(data: pngData),
              let cgImageFull = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw HVMError.backend(.vzInternal(description: "OCR: 解码 PNG 失败"))
        }

        // region 裁剪 (guest 像素左上原点 → CGImage 左上原点直接用)
        let cgImage: CGImage
        let regionWidth: CGFloat
        let regionHeight: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        if let r = region {
            guard let cropped = cgImageFull.cropping(to: r) else {
                throw HVMError.backend(.vzInternal(description: "OCR: cropping 失败 region=\(r)"))
            }
            cgImage = cropped
            originX = r.origin.x
            originY = r.origin.y
            regionWidth = r.width
            regionHeight = r.height
        } else {
            cgImage = cgImageFull
            originX = 0
            originY = 0
            regionWidth = CGFloat(cgImageFull.width)
            regionHeight = CGFloat(cgImageFull.height)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw HVMError.backend(.vzInternal(description: "OCR perform: \(error)"))
        }

        guard let observations = request.results else { return [] }

        var items: [TextItem] = []
        items.reserveCapacity(observations.count)
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let bn = obs.boundingBox  // 0-1 normalized, lower-left origin (相对 cgImage)
            // 转回 guest 像素左上原点, 加上 region origin 偏移
            let px = originX + bn.origin.x * regionWidth
            let py = originY + (1 - bn.origin.y - bn.height) * regionHeight
            let pw = bn.width  * regionWidth
            let ph = bn.height * regionHeight
            items.append(TextItem(
                x: Int(px.rounded()),
                y: Int(py.rounded()),
                width: Int(pw.rounded()),
                height: Int(ph.rounded()),
                text: cand.string,
                confidence: cand.confidence
            ))
        }
        return items
    }
}
