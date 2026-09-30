import SwiftUI
import MetalKit
import CoreImage
import CoreVideo
@preconcurrency import LiveKitWebRTC

struct RemoteVideoView: UIViewRepresentable {
    let video: RemoteVideoTrack
    let fill: Bool

    func makeUIView(context: Context) -> MetalVideoView { MetalVideoView() }
    func updateUIView(_ view: MetalVideoView, context: Context) {
        view.frames = video.frames
        view.fill = fill
    }
    static func dismantleUIView(_ view: MetalVideoView, coordinator: ()) {
        view.isPaused = true
        view.frames = nil
    }
}

@MainActor
final class MetalVideoView: MTKView {
    var frames: VideoFrameMailbox? {
        didSet { if oldValue !== frames { lastTimestamp = nil } }
    }
    var fill = false
    private var imageContext: CIContext?
    private var commands: MTLCommandQueue?
    private var lastTimestamp: Int64?
    private var lastSize = CGSize.zero
    private var lastFill = false
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let inFlight = DispatchSemaphore(value: 2)

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 60
        isPaused = false
        isOpaque = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let device {
            imageContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            commands = device.makeCommandQueue()
        }
    }
    required init(coder: NSCoder) { fatalError("Use init()") }

    override func draw(_ rect: CGRect) {
        guard let frame = frames?.snapshot(), let imageContext, let commands,
              drawableSize.width > 0, drawableSize.height > 0,
              frame.timeStampNs != lastTimestamp || drawableSize != lastSize || fill != lastFill,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let command = commands.makeCommandBuffer(),
              var image = Self.image(from: frame) else { inFlight.signal(); return }
        let exif: Int32
        switch frame.rotation.rawValue {
        case 90: exif = 6
        case 180: exif = 3
        case 270: exif = 8
        default: exif = 1
        }
        image = image.oriented(forExifOrientation: exif)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Core Image and an MTKView drawable use opposite vertical origins. Rendering the
        // CIImage directly into the Metal texture otherwise displays every frame upside down.
        image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
        image = image.transformed(by: CGAffineTransform(translationX: 0, y: -image.extent.minY))
        let x = drawableSize.width / image.extent.width, y = drawableSize.height / image.extent.height
        let scale = fill ? max(x, y) : min(x, y)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (drawableSize.width - image.extent.width) / 2,
                                                       y: (drawableSize.height - image.extent.height) / 2))
        let bounds = CGRect(origin: .zero, size: drawableSize)
        image = image.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        imageContext.render(image, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        command.present(drawable)
        // Keep decoder buffers alive until GPU consumption completes.
        command.addCompletedHandler { [inFlight, frame, image] _ in
            withExtendedLifetime((frame, image)) {}
            inFlight.signal()
        }
        command.commit()
        lastTimestamp = frame.timeStampNs; lastSize = drawableSize; lastFill = fill
    }

    private static func image(from frame: LKRTCVideoFrame) -> CIImage? {
        if let buffer = frame.buffer as? LKRTCCVPixelBuffer {
            let image = CIImage(cvPixelBuffer: buffer.pixelBuffer)
            // Core Image uses a lower-left origin; WebRTC crop coordinates use top-left.
            let crop = CGRect(x: Int(buffer.cropX),
                              y: CVPixelBufferGetHeight(buffer.pixelBuffer) - Int(buffer.cropY + buffer.cropHeight),
                              width: Int(buffer.cropWidth), height: Int(buffer.cropHeight))
            return image.cropped(to: crop)
        }
        // Software-decoder fallback. H.264 hardware decoding normally takes the zero-copy path above.
        let planar = frame.buffer.toI420()
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(planar.width), Int(planar.height),
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<Int(planar.height) {
            memcpy(yBase.advanced(by: row * yStride), planar.dataY.advanced(by: row * Int(planar.strideY)), Int(planar.width))
        }
        for row in 0..<Int(planar.chromaHeight) {
            let target = uvBase.assumingMemoryBound(to: UInt8.self).advanced(by: row * uvStride)
            for col in 0..<Int(planar.chromaWidth) {
                target[col * 2] = planar.dataU[row * Int(planar.strideU) + col]
                target[col * 2 + 1] = planar.dataV[row * Int(planar.strideV) + col]
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return CIImage(cvPixelBuffer: buffer)
    }
}
