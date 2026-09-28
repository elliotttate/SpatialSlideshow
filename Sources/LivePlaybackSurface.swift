import AVKit
import MetalKit
import OSLog

struct LiveRenderSettings: Codable, Equatable {
    var seconds: Double = 9
    var strength: Double = 1.8
    var pattern: Int = -1
    var zoomOut: Int = 0
    var longEdge: Int = 3840
}

/// One GPU compositor for live Gaussian scenes, video fallbacks and crossfades.
/// The playback engine still owns ordering, navigation and the shared timeline.
final class LivePlaybackSurface: NSView {
    private let canvas: PlaybackMetalCanvas?
    private weak var playback: ContinuousPlayback?
    private let videos = [PlaybackVideoFrame(), PlaybackVideoFrame()]
    private let loader = DispatchQueue(label: "SpatialSlideshow.SceneLoading", qos: .userInitiated)
    private let logger = Logger(subsystem: "local.photos-spatial-slideshow.screensaver", category: "LiveScenes")
    private var slots = [Slot(), Slot()]
    private var epoch = 0
    var cacheRoot = ScreenSaverStorage.root
    var onSceneLoaded: ((URL) -> Void)?
    private var retainedFrame: CIImage?
    private var retainedTextures: [MTLTexture] = []
    private var textureIndex = 0
    private var retainedContext: CIContext?
    private var pausedSignature: String?
    private(set) var manualCameraOffset = CGPoint.zero
    private var manualCameraTarget = CGPoint.zero
    private var manualKeys: Set<UInt16> = []
    private var manualSceneToken: String?
    private var manualTime = CACurrentMediaTime()
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var sceneRenderCount = 0
    var settings = LiveRenderSettings() {
        didSet { playback?.sceneDuration = max(3, settings.seconds) }
    }
    var fallbackClips: [URL: URL] = [:]
    var onFallback: ((String) -> Void)?
    var available: Bool { canvas != nil }
    var renderedFrameCount: Int { canvas?.renderedFrameCount ?? 0 }
    var canExplore: Bool {
        guard let playback, !playback.isPlaying, let index = currentSceneIndex else { return false }
        return slots[index].scene != nil && slots[index].url == playback.sceneURLs[index]
    }
    private var currentSceneIndex: Int? {
        guard let playback else { return nil }
        return playback.videoLayers.indices.first { playback.videoLayers[$0].zPosition == 0 && playback.sceneURLs[$0] != nil }
    }

    @discardableResult
    func moveManualCamera(x: CGFloat, y: CGFloat) -> Bool {
        guard canExplore, x.isFinite, y.isFinite else { return false }
        synchronizeManualCamera()
        manualCameraTarget.x = min(1, max(-1, manualCameraTarget.x + x))
        manualCameraTarget.y = min(1, max(-1, manualCameraTarget.y + y))
        return true
    }
    @discardableResult
    func setManualKey(_ key: UInt16, pressed: Bool) -> Bool {
        guard [UInt16(0), 1, 2, 13].contains(key) else { return false }
        if !pressed { return manualKeys.remove(key) != nil }
        guard canExplore else { return false }
        synchronizeManualCamera()
        if manualKeys.insert(key).inserted {
            // A quick tap may begin and end between display frames. Give it a
            // small nudge too; held keys then continue at a time-based speed.
            let x: CGFloat = key == 2 ? 0.06 : key == 0 ? -0.06 : 0
            let y: CGFloat = key == 1 ? 0.06 : key == 13 ? -0.06 : 0
            manualCameraTarget.x = min(1, max(-1, manualCameraTarget.x + x))
            manualCameraTarget.y = min(1, max(-1, manualCameraTarget.y + y))
        }
        return true
    }
    func clearManualKeys() { manualKeys.removeAll() }
    private func resetManualCamera() {
        manualCameraOffset = .zero; manualCameraTarget = .zero
        manualKeys.removeAll(); manualSceneToken = nil; manualTime = CACurrentMediaTime()
    }
    private func synchronizeManualCamera() {
        let now = CACurrentMediaTime()
        let delta = min(0.05, max(0, now - manualTime)); manualTime = now
        guard let playback, let index = currentSceneIndex else { resetManualCamera(); return }
        let token = "\(playback.sceneURLs[index]!)|\(playback.sceneGeneration[index])"
        if manualSceneToken != token { resetManualCamera(); manualSceneToken = token }
        if playback.isPlaying { manualKeys.removeAll(); manualCameraTarget = .zero }
        else if !manualKeys.isEmpty {
            var x: CGFloat = (manualKeys.contains(2) ? 1 : 0) - (manualKeys.contains(0) ? 1 : 0)
            var y: CGFloat = (manualKeys.contains(1) ? 1 : 0) - (manualKeys.contains(13) ? 1 : 0)
            let length = max(1, hypot(x, y)); x /= length; y /= length
            manualCameraTarget.x = min(1, max(-1, manualCameraTarget.x + x * delta * 1.5))
            manualCameraTarget.y = min(1, max(-1, manualCameraTarget.y + y * delta * 1.5))
        }
        // Ease pointer/scroll deltas and the handoff back to the moving path.
        let blend = 1 - exp(-delta * (playback.isPlaying ? 8 : 18))
        manualCameraOffset.x += (manualCameraTarget.x - manualCameraOffset.x) * blend
        manualCameraOffset.y += (manualCameraTarget.y - manualCameraOffset.y) * blend
        if abs(manualCameraOffset.x - manualCameraTarget.x) < 0.0001 { manualCameraOffset.x = manualCameraTarget.x }
        if abs(manualCameraOffset.y - manualCameraTarget.y) < 0.0001 { manualCameraOffset.y = manualCameraTarget.y }
    }
    private struct Slot {
        var url: URL?
        var generation = -1
        var scene: LiveGaussianScene?
        var lease: SceneCache.Lease?
        var loading = false
        var failed = false
        var pattern = 0
    }

    override init(frame: NSRect) {
        if let device = MTLCreateSystemDefaultDevice() {
            canvas = PlaybackMetalCanvas(frame: frame, device: device)
        } else { canvas = nil }
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        if let canvas {
            if let device = canvas.device { retainedContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
            canvas.frame = bounds; canvas.autoresizingMask = [.width, .height]
            canvas.makeFrame = { [weak self] size, command in self?.composite(size: size, command: command) }
            addSubview(canvas)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); canvas?.frame = bounds }
    func bind(_ playback: ContinuousPlayback) {
        if self.playback === playback { return }
        unbind()
        self.playback = playback
        playback.usesExternalFrameClock = true
        playback.sceneDuration = max(3, settings.seconds)
        playback.requiresDisplayReady = true
        playback.sceneIsReady = { [weak self] index, url in
            self?.slots[index].url == url && self?.slots[index].scene != nil
        }
        playback.frameIsReady = { [weak self, weak playback] layer in
            guard let self, let index = playback?.videoLayers.firstIndex(where: { $0 === layer }) else { return false }
            return self.videos[index].image != nil
        }
        canvas?.isPaused = false
    }
    func unbind() {
        epoch += 1
        playback?.usesExternalFrameClock = false
        playback?.frameIsReady = nil; playback?.sceneIsReady = nil
        playback = nil
        canvas?.isPaused = true; canvas?.clear()
        slots = [Slot(), Slot()]; videos.forEach { $0.reset() }
        retainedFrame = nil; retainedTextures = []; pausedSignature = nil
        resetManualCamera()
    }
    func snapshot() -> CGImage? { canvas?.snapshot() }

    private func synchronizeScenes(_ playback: ContinuousPlayback) {
        guard let device = canvas?.device else { return }
        for index in 0..<2 {
            let url = playback.sceneURLs[index], generation = playback.sceneGeneration[index]
            if slots[index].url != url { slots[index] = Slot(url: url) }
            if slots[index].generation != generation {
                slots[index].generation = generation
                slots[index].pattern = settings.pattern < 0 ? Int.random(in: 0..<6) : settings.pattern
            }
            if let url, slots[index].scene != nil { onSceneLoaded?(url) }
            guard let url, slots[index].scene == nil, !slots[index].loading, !slots[index].failed else { continue }
            slots[index].loading = true
            let token = epoch, root = cacheRoot
            loader.async { [weak self] in
                let lease = SceneCache.lease(url, root: root)
                let result = Result { try LiveGaussianScene(url: url, device: device) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.epoch == token, self.slots[index].url == url else { return }
                    self.slots[index].loading = false
                    switch result {
                    case .success(let scene):
                        self.slots[index].scene = scene; self.slots[index].lease = lease
                        self.onSceneLoaded?(url)
                        self.logger.info("Loaded live scene in slot \(index)")
                    case .failure(let error): self.fail(index: index, url: url, error: error)
                    }
                }
            }
        }
    }
    private func fail(index: Int, url: URL, error: Error) {
        guard !slots[index].failed else { return }
        slots[index].failed = true; slots[index].scene = nil
        onSceneLoaded?(url) // Release queued-file protection after a failed load.
        let message = "Live rendering: \(error.localizedDescription)"
        logger.error("\(message, privacy: .public)")
        if let clip = fallbackClips[url], FileManager.default.fileExists(atPath: clip.path) {
            playback?.replaceSceneWithClip(sceneURL: url, clipURL: clip)
            onFallback?("Using a prepared clip because this 3D scene could not be rendered.")
        } else { playback?.sceneFailed(slot: index, url: url, error: error) }
    }
    private func composite(size: CGSize, command: MTLCommandBuffer) -> CIImage? {
        guard let playback else { return nil }
        synchronizeScenes(playback)
        let target = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: target)
        let layers = playback.videoLayers
        let hostTime = CACurrentMediaTime() + 1.0 / 60
        for index in 0..<2 { videos[index].update(player: layers[index].player, hostTime: hostTime) }
        playback.advanceFrame()
        synchronizeManualCamera()
        guard playback.hasCurrentItem else { retainedFrame = nil; pausedSignature = nil; return black }
        let videoIdentities = layers.map { $0.player?.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "none" }
        let signature = "\(videoIdentities)|\(playback.displayedNumber ?? -1)|\(videos.map { $0.generation })|\(layers.map { $0.zPosition })|\(playback.sceneURLs)|\(playback.sceneGeneration)|\(playback.sceneProgress)|\(playback.transitionFraction)|\(settings)|\(size)|\(layers.map { $0.videoGravity.rawValue })|\(slots.map { $0.scene != nil })|\(manualCameraOffset)"
        if !playback.isPlaying, signature == pausedSignature, let retainedFrame { return retainedFrame }
        var result = black
        var hasCurrentImage = false
        for index in layers.indices.sorted(by: { layers[$0].zPosition < layers[$1].zPosition }) {
            guard layers[index].opacity > 0 else { continue }
            let image: CIImage?
            if let url = playback.sceneURLs[index] {
                guard slots[index].url == url, let scene = slots[index].scene else { continue }
                let scale = min(1, Double(max(256, min(settings.longEdge, playback.isTransitioning ? 1920 : 3840))) / max(size.width, size.height))
                do {
                    let rendered = try scene.encodeFrame(with: command, width: UInt(max(1, Int(size.width * scale))),
                        height: UInt(max(1, Int(size.height * scale))), fit: layers[index].videoGravity != .resizeAspectFill,
                        pattern: UInt(settings.pattern < 0 ? slots[index].pattern : settings.pattern),
                        progress: Float(playback.sceneProgress[index]), strength: Float(settings.strength),
                        zoomOut: Float(settings.zoomOut), manualX: Float(manualCameraOffset.x), manualY: Float(manualCameraOffset.y))
                    sceneRenderCount += 1
                    image = rendered.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)).cropped(to: target)
                } catch { fail(index: index, url: url, error: error); image = nil }
            } else if let decoded = videos[index].image {
                let width = decoded.extent.width, height = decoded.extent.height
                let scale = layers[index].videoGravity == .resizeAspectFill
                    ? max(size.width / width, size.height / height) : min(size.width / width, size.height / height)
                image = decoded.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                    tx: (size.width - width * scale) / 2, ty: (size.height - height * scale) / 2))
                    .composited(over: black).cropped(to: target)
            } else { image = nil }
            guard let image else { continue }
            if layers[index].zPosition == 0 { hasCurrentImage = true }
            if layers[index].opacity >= 1 { result = image }
            else { result = result.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: image, kCIInputTimeKey: layers[index].opacity]) }
        }
        // Keep an owned GPU copy through failed loads / clip fallback. The
        // source scene's ping-pong textures may be recycled on later frames.
        guard hasCurrentImage else { return retainedFrame ?? result }
        pausedSignature = signature
        guard let device = canvas?.device, let retainedContext else { return result }
        if retainedTextures.first?.width != Int(size.width) || retainedTextures.first?.height != Int(size.height) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(size.width), height: Int(size.height), mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            retainedTextures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            textureIndex = 0
        }
        guard retainedTextures.count == 2 else { return result }
        let texture = retainedTextures[textureIndex]; textureIndex = 1 - textureIndex
        retainedContext.render(result, to: texture, commandBuffer: command, bounds: target, colorSpace: outputColorSpace)
        let saved = CIImage(mtlTexture: texture, options: [.colorSpace: outputColorSpace])
        retainedFrame = saved
        return saved ?? result
    }
}
