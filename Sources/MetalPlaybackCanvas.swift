import AVKit
import CoreImage
import MetalKit
import OSLog

/// Retain decoded video surfaces without copying full-resolution frames to CPU
/// bitmaps. AVPlayerLayer itself is unreliable in the legacy screen saver host.
final class PlaybackVideoFrame {
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private(set) var image: CIImage?
    private(set) var generation = 0

    func update(player: AVPlayer?, hostTime: CFTimeInterval) {
        guard let current = player?.currentItem else { reset(); return }
        if item !== current {
            reset()
            item = current
            let newOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            newOutput.suppressesPlayerRendering = true
            current.add(newOutput)
            output = newOutput
        }
        guard let player, let output else { return }
        // Sample for presentation time, not the slightly earlier CPU callback.
        let mappedTime = output.itemTime(forHostTime: hostTime)
        let time = mappedTime.isNumeric ? mappedTime : player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        image = CIImage(cvPixelBuffer: buffer)
        generation += 1
    }
    func reset() {
        if output != nil || image != nil { generation += 1 }
        if let item, let output { item.remove(output) }
        item = nil; output = nil; image = nil
    }
}

final class PlaybackPresentationStats: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func presented() { lock.lock(); count += 1; lock.unlock() }
    func takeCount() -> Int { lock.lock(); defer { lock.unlock() }; let value = count; count = 0; return value }
}

final class PlaybackMetalCanvas: MTKView, MTKViewDelegate {
    var makeFrame: ((CGSize, MTLCommandBuffer) -> CIImage?)?
    private var imageContext: CIContext?
    private var commandQueue: MTLCommandQueue?
    private var lastFrame: CIImage?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let inFlight = DispatchSemaphore(value: 2)
    private let presentation = PlaybackPresentationStats()
    private let logger = Logger(subsystem: "local.photos-spatial-slideshow.screensaver", category: "Rendering")
    private var measuredSince = CACurrentMediaTime()
    private var measuredFrames = 0
    private var measuredCPU = 0.0
    private(set) var renderedFrameCount = 0

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        configure()
    }
    required init(coder: NSCoder) { super.init(coder: coder); configure() }
    private func configure() {
        guard let device else { return }
        imageContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        commandQueue = device.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        colorspace = colorSpace
        framebufferOnly = false
        preferredFramesPerSecond = 60
        isPaused = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        delegate = self
    }
    func clear() { lastFrame = nil }
    func snapshot() -> CGImage? {
        guard let lastFrame else { return nil }
        return imageContext?.createCGImage(lastFrame, from: lastFrame.extent, format: .RGBA8, colorSpace: colorSpace)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let started = CACurrentMediaTime()
        guard let imageContext, let commandQueue,
              inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let command = commandQueue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let image = makeFrame?(size, command) ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        lastFrame = image
        imageContext.render(image, to: drawable.texture, commandBuffer: command,
                            bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        let semaphore = inFlight, stats = presentation
        command.addCompletedHandler { [logger] command in
            semaphore.signal()
            if let error = command.error { logger.error("Metal render failed: \(error.localizedDescription, privacy: .public)") }
        }
        drawable.addPresentedHandler { _ in stats.presented() }
        command.present(drawable)
        command.commit()
        renderedFrameCount += 1; measuredFrames += 1
        measuredCPU += CACurrentMediaTime() - started
        let elapsed = CACurrentMediaTime() - measuredSince
        if elapsed >= 10 {
            let submittedFPS = Double(measuredFrames) / elapsed
            let presentedFPS = Double(presentation.takeCount()) / elapsed
            let cpuMS = measuredCPU * 1000 / Double(measuredFrames)
            logger.info("Metal renderer: submitted \(submittedFPS, format: .fixed(precision: 1)) fps, presented \(presentedFPS, format: .fixed(precision: 1)) fps; CPU \(cpuMS, format: .fixed(precision: 2)) ms/frame; \(Int(size.width))x\(Int(size.height))")
            measuredSince = CACurrentMediaTime(); measuredFrames = 0; measuredCPU = 0
        }
    }
}
