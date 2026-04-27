// FramebufferRenderer.swift
//
// Metal 全屏渲染器: 把 SURFACE_NEW 携带的 POSIX shm framebuffer 零拷贝绘到 MTKView.
//
// 关键链路:
//   1. SURFACE_NEW 携带 shm fd (SCM_RIGHTS), 由 DisplayChannel 转交
//   2. mmap shm → MTLBuffer.bytesNoCopy: GPU 与 host 共享同一物理页, 零拷贝
//   3. MTLBuffer.makeTexture(...): 把 buffer 视图为 BGRA8 2D 纹理
//   4. fullscreen pipeline (4-vertex triangle strip) + sample 纹理 → drawable
//
// 性能: BGRA8 1080p ≈ 8MB, 不 copy; QEMU 端 dpy_gfx_update 拷一次 (pixman→shm),
// host 端从 shm 直接采样到 GPU. 30Hz 帧率 CPU overhead 极低.

import Foundation
import Metal
import MetalKit
import Darwin

/// 单 VM 一个实例; 跟 FramebufferHostView 1:1 绑定.
public final class FramebufferRenderer: NSObject {

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// 当前 framebuffer 纹理. GPU 私有内存 (.storageModeShared 对 Apple Silicon
    /// 仍然 GPU 端 zero-copy, 只是不直接 backing 自 host shm), 每帧 draw 前从
    /// mappedShm replaceRegion 整张. 不用 MTLBuffer.makeTexture(bytesNoCopy:)
    /// 因为 M3 Max 上 _mtlValidateStrideTextureParameters 对 buffer.length ==
    /// bytesPerRow * height 的临界情况严格验证失败 (M1/M2 通过, M3 不通过).
    private var currentTexture: MTLTexture?

    /// shm mmap 起点; 单独持有, 跟 texture 生命周期解耦
    private var mappedShm: UnsafeMutableRawPointer?
    private var mappedSize: Int = 0
    private var mappedWidth: Int = 0
    private var mappedHeight: Int = 0
    private var mappedStride: Int = 0

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

    deinit { unbindShm() }

    // MARK: - shm lifecycle

    /// 接管 SCM_RIGHTS 拿到的 shm fd. 成功返回 true, 失败返回 false.
    /// 不论成功失败, fd 都被本方法 close (mmap 已持有引用 / 失败时直接 close).
    @discardableResult
    public func bindShm(fd: Int32, info: HDP.SurfaceNew) -> Bool {
        guard info.format == HDP.PixelFormat.bgra8.rawValue else {
            Darwin.close(fd)
            return false
        }
        let size = Int(info.shmSize)
        guard size > 0,
              size >= Int(info.stride) * Int(info.height) else {
            Darwin.close(fd)
            return false
        }
        guard let raw = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0),
              raw != UnsafeMutableRawPointer(bitPattern: -1) else {
            Darwin.close(fd)
            return false
        }
        // mmap 成功后我们的 fd 副本可释放, mmap 持有内核引用直到 munmap.
        Darwin.close(fd)

        unbindShm()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width:  Int(info.width),
            height: Int(info.height),
            mipmapped: false)
        desc.storageMode = .shared
        desc.usage       = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else {
            munmap(raw, size)
            return false
        }

        currentTexture = tex
        mappedShm      = raw
        mappedSize     = size
        mappedWidth    = Int(info.width)
        mappedHeight   = Int(info.height)
        mappedStride   = Int(info.stride)
        return true
    }

    public func unbindShm() {
        currentTexture = nil
        if let p = mappedShm {
            munmap(p, mappedSize)
            mappedShm = nil
        }
        mappedSize = 0
        mappedWidth = 0
        mappedHeight = 0
        mappedStride = 0
    }

    // MARK: - draw

    /// 在 MTKView 当前 drawable 上绘. 在 MTKViewDelegate.draw(in:) 里调.
    /// MTKView.currentDrawable / currentRenderPassDescriptor 是 @MainActor isolated,
    /// 因此本函数也标 @MainActor (调用方 FramebufferHostView 的 MTKViewDelegate
    /// draw(in:) 已在 main actor 上, 无 hop 开销).
    @MainActor
    public func draw(in view: MTKView) {
        // 每帧从 shm 同步整张 framebuffer 到 GPU texture (.storageModeShared
        // 在 Apple Silicon UMA 上 replace 几乎免费; 1080p ≈ 130μs per frame).
        // 不依赖 SURFACE_DAMAGE 局部更新, 简单可靠.
        if let tex = currentTexture, let raw = mappedShm,
           mappedWidth > 0, mappedHeight > 0, mappedStride > 0 {
            let region = MTLRegionMake2D(0, 0, mappedWidth, mappedHeight)
            tex.replace(region: region, mipmapLevel: 0,
                        withBytes: raw, bytesPerRow: mappedStride)
        }

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
