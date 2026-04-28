// FramebufferRenderer.swift
//
// Metal 全屏渲染器: 把 SURFACE_NEW 携带的 POSIX shm framebuffer 零拷贝绘到 MTKView.
//
// 关键链路 (零拷贝, hell-vm 同款方案):
//   1. SURFACE_NEW 携带 shm fd (SCM_RIGHTS), 由 DisplayChannel 转交
//   2. mmap shm → device.makeBuffer(bytesNoCopy:): GPU 与 host 共享同一物理页
//   3. buffer.makeTexture(descriptor:offset:bytesPerRow:): texture 直接 view 自 mmap
//   4. fullscreen pipeline + fragment shader 采样 → drawable (无任何 CPU memcpy)
//
// 关键约束: bytesPerRow 必须 ≥256B 对齐, 否则 M3+ 的 _mtlValidateStrideTextureParameters
// 会 abort. 这要求 QEMU iosurface backend 的 shm stride 已被 padding 到 256
// (patches/qemu/0002 里 IOS_STRIDE_ALIGN). 客户端直接信任 info.stride, 不自己推.
//
// 性能: 30Hz draw 只触发 GPU encode + present, CPU 端 0 拷贝; QEMU 端 dpy_gfx_update
// 仍然只拷 dirty 区到 shm. 1080p 全屏动画在 M3 Max 上稳 30Hz 接近 0% CPU.

import Foundation
import Metal
import MetalKit
import Darwin
import HVMCore

/// 单 VM 一个实例; 跟 FramebufferHostView 1:1 绑定.
public final class FramebufferRenderer: NSObject {

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// 当前 framebuffer 纹理 (view 自 currentBuffer 的 BGRA8 2D 视图, 不独立持内存).
    private var currentTexture: MTLTexture?

    /// 当前 framebuffer 后端 buffer: bytesNoCopy 包了 mappedShm, deallocator
    /// 在 GPU 释放最后一个引用时 munmap. 持引用即可保活, 不用手动 munmap.
    private var currentBuffer: MTLBuffer?

    /// 当前 surface 几何信息. snapshotCGImage 用它构造 CGImage; draw() 不需要
    /// (texture 自带 width/height).
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var currentStride: Int = 0

    public override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("FramebufferRenderer: Metal not available on this host")
        }
        guard let queue = device.makeCommandQueue() else {
            preconditionFailure("FramebufferRenderer: command queue creation failed")
        }

        // 内嵌 Metal Shading Language: 4-vertex triangle strip 全屏 + 采样纹理.
        // 不依赖 SwiftPM .metal 编译流程 (编译期需要 Xcode shader compiler 链).
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VOut {
            float4 position [[position]];
            float2 uv;
        };

        // NDC 全屏 quad (triangle strip):
        //   (-1,-1) (1,-1) (-1,1) (1,1)
        // UV 注意: 纹理原点在左上, 我们的 BGRA framebuffer 也是左上, uv.y 顺序匹配 (0=top).
        vertex VOut hvm_fb_vertex(uint vid [[vertex_id]]) {
            const float2 positions[4] = { float2(-1.0, -1.0),
                                          float2( 1.0, -1.0),
                                          float2(-1.0,  1.0),
                                          float2( 1.0,  1.0) };
            const float2 uvs[4] = { float2(0.0, 1.0),
                                    float2(1.0, 1.0),
                                    float2(0.0, 0.0),
                                    float2(1.0, 0.0) };
            VOut o;
            o.position = float4(positions[vid], 0.0, 1.0);
            o.uv = uvs[vid];
            return o;
        }

        fragment float4 hvm_fb_fragment(VOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler s [[sampler(0)]]) {
            return tex.sample(s, in.uv);
        }
        """
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            preconditionFailure("FramebufferRenderer: shader compile failed: \(error)")
        }

        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction   = library.makeFunction(name: "hvm_fb_vertex")
        pdesc.fragmentFunction = library.makeFunction(name: "hvm_fb_fragment")
        pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pdesc)
        } catch {
            preconditionFailure("FramebufferRenderer: pipeline creation failed: \(error)")
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter    = .linear
        sd.magFilter    = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else {
            preconditionFailure("FramebufferRenderer: sampler creation failed")
        }

        self.device       = device
        self.commandQueue = queue
        self.pipeline     = pipeline
        self.sampler      = sampler
        super.init()
    }

    deinit {
        // MTLBuffer 随对象释放, deallocator 会自动 munmap, 这里无需任何动作.
    }

    // MARK: - shm lifecycle

    /// 接管 SCM_RIGHTS 拿到的 shm fd. 成功返回 true, 失败返回 false.
    /// 不论成功失败, fd 都被本方法 close (mmap 已持有引用 / 失败时直接 close).
    /// @MainActor: bindShm 改写 currentBuffer / currentTexture, 跟 30Hz draw(in:) 串行.
    @MainActor
    @discardableResult
    public func bindShm(fd: Int32, info: HDP.SurfaceNew) -> Bool {
        guard info.format == HDP.PixelFormat.bgra8.rawValue else {
            Darwin.close(fd)
            return false
        }
        let size = Int(info.shmSize)
        let stride = Int(info.stride)
        let width  = Int(info.width)
        let height = Int(info.height)
        // QEMU 端 IOS_STRIDE_ALIGN=256 已保证 stride 256B 对齐, 客户端只校验下界
        // (Apple Silicon Metal 至少要 16B 对齐, 256B 自然满足) + 不能 < width*4.
        guard size > 0, stride >= width * 4, stride % 16 == 0,
              size >= stride * height else {
            Darwin.close(fd)
            return false
        }
        guard let raw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              raw != UnsafeMutableRawPointer(bitPattern: -1) else {
            Darwin.close(fd)
            return false
        }
        // mmap 成功后我们的 fd 副本可释放, mmap 持有内核引用直到 munmap.
        Darwin.close(fd)

        // bytesNoCopy: MTLBuffer 直接 view 自 mmap 内存; deallocator 在 GPU 释放
        // 最后一个引用后 munmap. PROT_READ|WRITE 是因为 .storageModeShared 要求
        // 可写映射 (Metal driver 内部可能写 cache control bits), 即便我们只读.
        let savedRaw  = raw
        let savedSize = size
        guard let buf = device.makeBuffer(
            bytesNoCopy: raw,
            length: size,
            options: .storageModeShared,
            deallocator: { _, _ in
                munmap(savedRaw, savedSize)
            }
        ) else {
            munmap(raw, size)
            return false
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width:  width,
            height: height,
            mipmapped: false)
        desc.storageMode = .shared
        desc.usage       = [.shaderRead]
        guard let tex = buf.makeTexture(descriptor: desc, offset: 0,
                                         bytesPerRow: stride) else {
            // buf 释放时 deallocator 会 munmap, 不再手动调.
            return false
        }

        // 老 buffer/texture 释放; MTLBuffer deallocator 自动 munmap 老 mapping.
        currentTexture = tex
        currentBuffer  = buf
        currentWidth   = width
        currentHeight  = height
        currentStride  = stride
        return true
    }

    @MainActor
    public func unbindShm() {
        // 释放引用, MTLBuffer deallocator 会 munmap.
        currentTexture = nil
        currentBuffer  = nil
        currentWidth = 0; currentHeight = 0; currentStride = 0
    }

    /// CGDataProvider 的 release callback 必须是 @convention(c), 不能 capture
    /// Swift 引用. 用 BufferBox 桥: passRetained 进 opaque ptr, release 时
    /// takeRetainedValue 平衡, 让 ARC 自然 dealloc MTLBuffer.
    private final class BufferBox {
        let buf: MTLBuffer
        init(_ b: MTLBuffer) { self.buf = b }
    }

    /// 抓一张当前 framebuffer 的 CGImage (零拷贝, view 自 MTLBuffer 内存).
    /// 调用方拿到 CGImage 后可在任意线程做 PNG encode / downscale: CGImage
    /// 用 CGDataProvider 持有 BufferBox 引用, 即便 main 之后 unbind / 切 surface,
    /// 老 buffer 也活到 CGImage 释放才 munmap, 不会读 dangling pointer.
    /// nil = 还没绑 surface.
    @MainActor
    public func snapshotCGImage() -> CGImage? {
        guard let buf = currentBuffer,
              currentWidth > 0, currentHeight > 0, currentStride > 0 else {
            return nil
        }
        let len = currentStride * currentHeight
        let opaqueBox = Unmanaged.passRetained(BufferBox(buf)).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: opaqueBox,
            data: buf.contents(),
            size: len,
            releaseData: { ctx, _, _ in
                guard let ctx else { return }
                _ = Unmanaged<BufferBox>.fromOpaque(ctx).takeRetainedValue()
            }
        ) else {
            // CGDataProvider 创建失败也得平衡 retain
            _ = Unmanaged<BufferBox>.fromOpaque(opaqueBox).takeRetainedValue()
            return nil
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        // QEMU iosurface backend 推的 byte order 是 BGRA (host little-endian =
        // pixman_x8r8g8b8); 在 CGImage 描述里用 .byteOrder32Little + noneSkipFirst.
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Little,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
        ]
        return CGImage(
            width:  currentWidth,
            height: currentHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: currentStride,
            space: cs,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - draw

    /// 在 MTKView 当前 drawable 上绘. 在 MTKViewDelegate.draw(in:) 里调.
    /// MTKView.currentDrawable / currentRenderPassDescriptor 是 @MainActor isolated,
    /// 因此本函数也标 @MainActor (调用方 FramebufferHostView 的 MTKViewDelegate
    /// draw(in:) 已在 main actor 上, 无 hop 开销).
    @MainActor
    public func draw(in view: MTKView) {
        // bytesNoCopy 路径: texture 直接 view 自 mmap 内存, fragment shader
        // 采样时 Apple Silicon UMA driver 自动同步 cache, 无需 CPU memcpy.
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // 没绑 surface 时仍要 present 一个空 drawable 让 MTKView 不卡帧.
        if let tex = currentTexture {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip,
                                    vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
