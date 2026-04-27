// HDPProtocol.swift
//
// HVM-QEMU 显示嵌入协议 (HDP) 的 Swift 端定义
//
// 协议规范 (canonical): docs/QEMU_DISPLAY_PROTOCOL.md v1.0.0
// C 端镜像头:           include/ui/hvm_display_proto.h (在 patches/qemu/0002 中)
//
// **同步规则**: 修改本文件必须同步上述两份文件并在协议规范文档 §13 追加版本条目.
// 三处不允许任何一处单独改, 否则 host 与 QEMU 二进制握手会失配.

import Foundation

/// HDP 协议命名空间. 所有协议级常量 / 类型 / 消息结构都封在这里.
public enum HDP {

    // MARK: - 版本号

    /// 协议起步版本 1.0.0
    public static let majorVersion: UInt32 = 1
    public static let minorVersion: UInt32 = 0
    public static let patchVersion: UInt32 = 0

    /// `(major<<16)|(minor<<8)|patch` — wire 上 HELLO 携带的 u32
    public static let protoVersion: UInt32 =
        (majorVersion << 16) | (minorVersion << 8) | patchVersion

    /// 解出 major 段 (跨 major 不兼容必须断连)
    public static func major(of version: UInt32) -> UInt32 {
        (version >> 16) & 0xFFFF
    }

    // MARK: - flags 字段

    public struct HeaderFlags: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        /// 本消息附带 SCM_RIGHTS fd, 接收方必须用 recvmsg
        public static let hasFD  = HeaderFlags(rawValue: 0x0001)
        /// 优先级提示, 收方可考虑插队
        public static let urgent = HeaderFlags(rawValue: 0x0002)
    }

    // MARK: - capability_flags 字段

    public struct Capabilities: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// 硬件光标 BGRA payload 支持
        public static let cursorBGRA     = Capabilities(rawValue: 0x00000001)
        /// guest LED 反向回传
        public static let ledState       = Capabilities(rawValue: 0x00000002)
        /// 动态分辨率 (vdagent virtio-serial 通道就绪)
        public static let vdagentResize  = Capabilities(rawValue: 0x00000004)

        /// host 端我们目标支持的全部 capability
        public static let hostAdvertised: Capabilities = [
            .cursorBGRA, .ledState, .vdagentResize,
        ]
    }

    // MARK: - 消息类型 ID

    public enum MessageType: UInt16, Sendable {
        case hello          = 0x0001
        case surfaceNew     = 0x0002
        case surfaceDamage  = 0x0003
        case cursorDefine   = 0x0010
        case cursorPos      = 0x0011
        case ledState       = 0x0020
        case resizeRequest  = 0x0080
        case goodbye        = 0x00FF
    }

    // MARK: - 像素格式

    public enum PixelFormat: UInt32, Sendable {
        case bgra8 = 0x00000001
    }

    // MARK: - GOODBYE 原因码

    public enum GoodbyeReason: UInt32, Sendable {
        case normal           = 0
        case versionMismatch  = 1
        case protocolError    = 2
        case internalError    = 3
    }

    // MARK: - 消息头 (8 bytes wire)

    public struct Header: Sendable {
        public static let byteSize = 8

        public var type: UInt16
        public var flags: HeaderFlags
        public var payloadLen: UInt32

        public init(type: UInt16, flags: HeaderFlags, payloadLen: UInt32) {
            self.type = type
            self.flags = flags
            self.payloadLen = payloadLen
        }

        public init(type: MessageType, flags: HeaderFlags, payloadLen: UInt32) {
            self.init(type: type.rawValue, flags: flags, payloadLen: payloadLen)
        }

        /// 序列化为 8 字节 little-endian
        public func encode() -> Data {
            var data = Data(capacity: Header.byteSize)
            data.appendLE(type)
            data.appendLE(flags.rawValue)
            data.appendLE(payloadLen)
            return data
        }

        /// 从 8 字节 little-endian 反序列化. 字节数不足返回 nil.
        public static func decode(_ bytes: Data) -> Header? {
            guard bytes.count >= byteSize else { return nil }
            var off = bytes.startIndex
            let type: UInt16    = bytes.readLE(at: &off)
            let flagsRaw: UInt16 = bytes.readLE(at: &off)
            let plen: UInt32    = bytes.readLE(at: &off)
            return Header(type: type,
                          flags: HeaderFlags(rawValue: flagsRaw),
                          payloadLen: plen)
        }
    }

    // MARK: - HELLO payload

    public struct Hello: Sendable {
        public static let byteSize = 8

        public var protoVersion: UInt32
        public var capabilities: Capabilities

        public init(protoVersion: UInt32, capabilities: Capabilities) {
            self.protoVersion = protoVersion
            self.capabilities = capabilities
        }

        public func encode() -> Data {
            var d = Data(capacity: Hello.byteSize)
            d.appendLE(protoVersion)
            d.appendLE(capabilities.rawValue)
            return d
        }

        public static func decode(_ payload: Data) -> Hello? {
            guard payload.count >= byteSize else { return nil }
            var off = payload.startIndex
            let pv: UInt32 = payload.readLE(at: &off)
            let cap: UInt32 = payload.readLE(at: &off)
            return Hello(protoVersion: pv, capabilities: Capabilities(rawValue: cap))
        }
    }

    // MARK: - SURFACE_NEW payload (header 必须含 hasFD; SCM_RIGHTS 走附带 fd)

    public struct SurfaceNew: Sendable {
        public static let byteSize = 24

        public var width: UInt32
        public var height: UInt32
        public var stride: UInt32
        public var format: UInt32
        public var shmSize: UInt64

        public init(width: UInt32, height: UInt32, stride: UInt32,
                    format: UInt32, shmSize: UInt64) {
            self.width = width
            self.height = height
            self.stride = stride
            self.format = format
            self.shmSize = shmSize
        }

        public func encode() -> Data {
            var d = Data(capacity: SurfaceNew.byteSize)
            d.appendLE(width); d.appendLE(height); d.appendLE(stride)
            d.appendLE(format); d.appendLE(shmSize)
            return d
        }

        public static func decode(_ payload: Data) -> SurfaceNew? {
            guard payload.count >= byteSize else { return nil }
            var off = payload.startIndex
            let w: UInt32 = payload.readLE(at: &off)
            let h: UInt32 = payload.readLE(at: &off)
            let s: UInt32 = payload.readLE(at: &off)
            let f: UInt32 = payload.readLE(at: &off)
            let sz: UInt64 = payload.readLE(at: &off)
            return SurfaceNew(width: w, height: h, stride: s, format: f, shmSize: sz)
        }
    }

    // MARK: - SURFACE_DAMAGE payload

    public struct SurfaceDamage: Sendable {
        public static let byteSize = 16

        public var x: UInt32
        public var y: UInt32
        public var w: UInt32
        public var h: UInt32

        public init(x: UInt32, y: UInt32, w: UInt32, h: UInt32) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }

        public func encode() -> Data {
            var d = Data(capacity: SurfaceDamage.byteSize)
            d.appendLE(x); d.appendLE(y); d.appendLE(w); d.appendLE(h)
            return d
        }

        public static func decode(_ payload: Data) -> SurfaceDamage? {
            guard payload.count >= byteSize else { return nil }
            var off = payload.startIndex
            let x: UInt32 = payload.readLE(at: &off)
            let y: UInt32 = payload.readLE(at: &off)
            let w: UInt32 = payload.readLE(at: &off)
            let h: UInt32 = payload.readLE(at: &off)
            return SurfaceDamage(x: x, y: y, w: w, h: h)
        }
    }

    // MARK: - CURSOR_DEFINE payload (struct 头 + width*height*4 BGRA bytes)

    public struct CursorDefine: Sendable {
        public static let headerByteSize = 8

        public var width: UInt16
        public var height: UInt16
        public var hotX: Int16
        public var hotY: Int16
        public var pixelsBGRA: Data  // width * height * 4 bytes

        public init(width: UInt16, height: UInt16,
                    hotX: Int16, hotY: Int16, pixelsBGRA: Data) {
            self.width = width
            self.height = height
            self.hotX = hotX
            self.hotY = hotY
            self.pixelsBGRA = pixelsBGRA
        }

        public func encode() -> Data {
            var d = Data(capacity: CursorDefine.headerByteSize + pixelsBGRA.count)
            d.appendLE(width); d.appendLE(height)
            d.appendLE(hotX); d.appendLE(hotY)
            d.append(pixelsBGRA)
            return d
        }

        public static func decode(_ payload: Data) -> CursorDefine? {
            guard payload.count >= headerByteSize else { return nil }
            var off = payload.startIndex
            let w: UInt16 = payload.readLE(at: &off)
            let h: UInt16 = payload.readLE(at: &off)
            let hx: Int16 = payload.readLE(at: &off)
            let hy: Int16 = payload.readLE(at: &off)
            let expectedPix = Int(w) * Int(h) * 4
            let pixStart = payload.startIndex + headerByteSize
            guard payload.count - headerByteSize >= expectedPix else { return nil }
            let pix = payload.subdata(in: pixStart ..< pixStart + expectedPix)
            return CursorDefine(width: w, height: h, hotX: hx, hotY: hy, pixelsBGRA: pix)
        }
    }

    // MARK: - CURSOR_POS payload

    public struct CursorPos: Sendable {
        public static let byteSize = 12

        public var x: Int32
        public var y: Int32
        public var visible: UInt32

        public init(x: Int32, y: Int32, visible: Bool) {
            self.x = x; self.y = y; self.visible = visible ? 1 : 0
        }

        public func encode() -> Data {
            var d = Data(capacity: CursorPos.byteSize)
            d.appendLE(x); d.appendLE(y); d.appendLE(visible)
            return d
        }

        public static func decode(_ payload: Data) -> CursorPos? {
            guard payload.count >= byteSize else { return nil }
            var off = payload.startIndex
            let x: Int32 = payload.readLE(at: &off)
            let y: Int32 = payload.readLE(at: &off)
            let v: UInt32 = payload.readLE(at: &off)
            var p = CursorPos(x: x, y: y, visible: v != 0)
            p.visible = v
            return p
        }
    }

    // MARK: - LED_STATE payload

    public struct LedState: Sendable {
        public static let byteSize = 12

        public var capsLock: Bool
        public var numLock: Bool
        public var scrollLock: Bool

        public init(capsLock: Bool, numLock: Bool, scrollLock: Bool) {
            self.capsLock = capsLock
            self.numLock = numLock
            self.scrollLock = scrollLock
        }

        public func encode() -> Data {
            var d = Data(capacity: LedState.byteSize)
            d.appendLE(UInt32(capsLock ? 1 : 0))
            d.appendLE(UInt32(numLock  ? 1 : 0))
            d.appendLE(UInt32(scrollLock ? 1 : 0))
            return d
        }

        public static func decode(_ payload: Data) -> LedState? {
            guard payload.count >= byteSize else { return nil }
            var off = payload.startIndex
            let c: UInt32 = payload.readLE(at: &off)
            let n: UInt32 = payload.readLE(at: &off)
            let s: UInt32 = payload.readLE(at: &off)
            return LedState(capsLock: c != 0, numLock: n != 0, scrollLock: s != 0)
        }
    }

    // MARK: - RESIZE_REQUEST payload (host → QEMU)

    public struct ResizeRequest: Sendable {
        public static let byteSize = 8

        public var width: UInt32
        public var height: UInt32

        public init(width: UInt32, height: UInt32) {
            self.width = width; self.height = height
        }

        public func encode() -> Data {
            var d = Data(capacity: ResizeRequest.byteSize)
            d.appendLE(width); d.appendLE(height)
            return d
        }

        public static func decode(_ payload: Data) -> ResizeRequest? {
            guard payload.count >= byteSize else { return nil }
            var off = payload.startIndex
            let w: UInt32 = payload.readLE(at: &off)
            let h: UInt32 = payload.readLE(at: &off)
            return ResizeRequest(width: w, height: h)
        }
    }

    // MARK: - GOODBYE payload

    public struct Goodbye: Sendable {
        public static let byteSize = 4

        public var reason: UInt32

        public init(reason: GoodbyeReason) { self.reason = reason.rawValue }
        public init(rawReason: UInt32) { self.reason = rawReason }

        public func encode() -> Data {
            var d = Data(capacity: Goodbye.byteSize)
            d.appendLE(reason)
            return d
        }

        public static func decode(_ payload: Data) -> Goodbye? {
            guard payload.count >= byteSize else { return nil }
            var off = payload.startIndex
            let r: UInt32 = payload.readLE(at: &off)
            return Goodbye(rawReason: r)
        }
    }
}

// MARK: - Data little-endian helpers
//
// 协议规范 §2: 一律 little-endian. host 是 arm64 / x86, 都 LE, 不需要 byteswap.
// 但显式写 LE 让协议层不依赖 host 假设, 一旦未来跨平台 (例如 Windows host)
// 也能保持正确.

extension Data {
    fileprivate mutating func appendLE(_ v: UInt8) {
        append(v)
    }
    fileprivate mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    fileprivate mutating func appendLE(_ v: Int16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    fileprivate mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    fileprivate mutating func appendLE(_ v: Int32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    fileprivate mutating func appendLE(_ v: UInt64) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    fileprivate func readLE(at off: inout Int) -> UInt8 {
        let v = self[off]
        off += 1
        return v
    }
    fileprivate func readLE(at off: inout Int) -> UInt16 {
        let v: UInt16 = self.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: off - startIndex, as: UInt16.self)
        }
        off += 2
        return UInt16(littleEndian: v)
    }
    fileprivate func readLE(at off: inout Int) -> Int16 {
        let v: Int16 = self.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: off - startIndex, as: Int16.self)
        }
        off += 2
        return Int16(littleEndian: v)
    }
    fileprivate func readLE(at off: inout Int) -> UInt32 {
        let v: UInt32 = self.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: off - startIndex, as: UInt32.self)
        }
        off += 4
        return UInt32(littleEndian: v)
    }
    fileprivate func readLE(at off: inout Int) -> Int32 {
        let v: Int32 = self.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: off - startIndex, as: Int32.self)
        }
        off += 4
        return Int32(littleEndian: v)
    }
    fileprivate func readLE(at off: inout Int) -> UInt64 {
        let v: UInt64 = self.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: off - startIndex, as: UInt64.self)
        }
        off += 8
        return UInt64(littleEndian: v)
    }
}
