import ScreenSaver
import AVKit
import OSLog
import CoreImage
import MetalKit

@objc(SpatialSlideshowScreenSaverView)
final class SpatialSlideshowScreenSaverView: ScreenSaverView {
    private var playback: ContinuousPlayback?
    private var loadedPlaylist: ScreenSaverPlaylist?
    private var clipNumbers: [String: Int] = [:]
    private var resolvedClips: [String: ScreenSaverClip] = [:]
    private var lastRefresh = Date.distantPast
    private var mediaRoot = ScreenSaverStorage.root
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let logger = Logger(subsystem: "local.photos-spatial-slideshow.screensaver", category: "Playback")
    private var canvas: LivePlaybackSurface?
    var playbackLayers: [AVPlayerLayer] { playback?.videoLayers ?? [] }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    convenience init?(frame: NSRect, isPreview: Bool, mediaRoot: URL) {
        self.init(frame: frame, isPreview: isPreview)
        self.mediaRoot = mediaRoot
    }
    private func setup() {
        // MetalKit owns display-synchronized drawing. The screen saver timer
        // only checks the shared playlist; it does not rasterize video frames.
        animationTimeInterval = 1
        let surface = LivePlaybackSurface(frame: bounds)
        if surface.available {
            surface.autoresizingMask = [.width, .height]
            addSubview(surface); canvas = surface
        }
        notice.textColor = .white; notice.alignment = .center
        notice.font = .systemFont(ofSize: isPreview ? 12 : 22)
        notice.isSelectable = false
        addSubview(notice)
        notice.stringValue = "Spatial Slideshow\nChoose a slideshow in the app’s Screen Saver settings."
    }
    override var isOpaque: Bool { true }
    override func draw(_ rect: NSRect) { NSColor.black.setFill(); rect.fill() }

    // On-demand readback for diagnostics/tests; normal playback stays on the GPU.
    func renderedFrameSnapshot() -> CGImage? { canvas?.snapshot() }
    var renderedFrameCount: Int { canvas?.renderedFrameCount ?? 0 }
    override func layout() {
        super.layout()
        canvas?.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playback?.videoLayers.forEach { $0.frame = bounds }
        CATransaction.commit()
        let width = max(0, min(600, bounds.width - 32))
        notice.frame = NSRect(x: (bounds.width - width) / 2, y: max(0, bounds.midY - 55), width: width, height: 110)
    }
    override func startAnimation() {
        super.startAnimation()
        refresh(force: true)
        if let playback { canvas?.bind(playback) }
    }
    override func stopAnimation() {
        super.stopAnimation()
        canvas?.unbind()
        clearPlayback()
    }
    private func clearPlayback() {
        playback?.stop()
        playback?.videoLayers.forEach { $0.removeFromSuperlayer() }
        playback = nil; loadedPlaylist = nil; clipNumbers = [:]; resolvedClips = [:]
        canvas?.unbind(); needsDisplay = true
    }
    override func animateOneFrame() {
        if Date().timeIntervalSince(lastRefresh) >= 10 { refresh(force: false) }

    }
    private func refresh(force: Bool) {
        lastRefresh = Date()
        let playlist: ScreenSaverPlaylist
        do { playlist = try ScreenSaverStorage.read(root: mediaRoot) }
        catch {
            if playback == nil {
                notice.isHidden = false
                notice.stringValue = "Spatial Slideshow\nOpen the app, play an album, and choose Use This Slideshow in Screen Saver settings."
                logger.error("Unable to read prepared playlist: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard canvas != nil else {
            notice.isHidden = false
            notice.stringValue = "Spatial Slideshow\nThe GPU renderer could not start. Restart your Mac and try again."
            return
        }
        guard playlist.enabled else {
            clearPlayback(); notice.isHidden = false
            notice.stringValue = "Spatial Slideshow\nScreen saver sharing is turned off in the app."
            return
        }
        if !force, playlist == loadedPlaylist { return }
        var clips = playlist.playableClips(root: mediaRoot)
        let removedClips = loadedPlaylist.map { !Set($0.clips.map(\.id)).isSubset(of: Set(playlist.clips.map(\.id))) } ?? false
        if loadedPlaylist?.selectionID != playlist.selectionID || playback == nil || removedClips {
            clearPlayback()
            if playlist.shuffle { clips.shuffle() }
        }
        guard !clips.isEmpty else {
            clearPlayback(); notice.isHidden = false
            notice.stringValue = "Spatial Slideshow\nPlay \(playlist.title) in the app to prepare photos for the screen saver."
            return
        }
        if playback == nil {
            let engine = ContinuousPlayback()
            engine.audioEnabled = false; engine.requiresDisplayReady = true
            engine.onFailure = { [weak self] error in self?.logger.error("Cached clip failed: \(error.localizedDescription, privacy: .public)") }
            engine.onItem = { [weak self] number in self?.logger.info("Playing prepared item \(number)") }
            engine.onReplay = { [weak self] number in self?.logger.info("Replaying prepared item \(number)") }
            playback = engine
            canvas?.bind(engine)
            engine.begin() // Remains open for newly prepared clips; loops fairly between available items.
            needsLayout = true; layoutSubtreeIfNeeded()
        }
        guard let playback else { return }
        playback.transitionDuration = playlist.crossfade ? 0.8 : 0
        canvas?.cacheRoot = mediaRoot
        canvas?.settings = playlist.liveSettings ?? LiveRenderSettings()
        canvas?.fallbackClips = Dictionary(clips.compactMap { clip, url in
            guard clip.isScene == true, let path = clip.fallbackRelativePath,
                  let fallback = ScreenSaverStorage.clipURL(path, root: mediaRoot) else { return nil }
            return (url, fallback)
        }, uniquingKeysWith: { first, _ in first })
        playback.shuffleReplays = playlist.shuffle
        playback.videoLayers.forEach { $0.videoGravity = playlist.fillScreen ? .resizeAspectFill : .resizeAspect }
        for (clip, url) in clips {
            let number = clipNumbers[clip.id] ?? clipNumbers.count
            clipNumbers[clip.id] = number
            if resolvedClips[clip.id] != clip {
                resolvedClips[clip.id] = clip
                if clip.isScene == true { playback.appendScene(url, number: number) }
                else { playback.append(url, number: number) }
            }
        }
        loadedPlaylist = playlist; notice.isHidden = true
        logger.info("Loaded \(clips.count) prepared clips; preview=\(self.isPreview)")
    }
}
