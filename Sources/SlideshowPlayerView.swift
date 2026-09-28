import AVKit

final class SlideshowPlayerView: AVPlayerView {
    private weak var playback: ContinuousPlayback?
    private let videoHost = SlideshowVideoHost()
    private var liveSurface: LivePlaybackSurface?
    private var fillScreen = true
    private var windowFullscreen = false
    private var keyMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    private var cameraDragPoint: NSPoint?
    private let transportBar = SlideshowTransportBar()
    private var controlsTimer: Timer?
    private var lastActivity = CACurrentMediaTime()
    private var lastPlaying: Bool?
    var arePhotoControlsVisible: Bool { !transportBar.isHidden }
    var onWindowChanged: ((NSWindow) -> Void)?
    var onSceneLoaded: ((URL) -> Void)?
    var onLiveFallback: ((String) -> Void)?
    var canExplorePausedScene: Bool { liveSurface?.canExplore == true }
    var manualCameraOffset: CGPoint { liveSurface?.manualCameraOffset ?? .zero }

    override init(frame: NSRect) {
        super.init(frame: frame)
        controlsStyle = .none
        // The app's NSWindow owns fullscreen. AVKit's separate fullscreen
        // presentation reparents the video and conflicts with our two layers.
        showsFullScreenToggleButton = false
        allowsPictureInPicturePlayback = false
        allowsVideoFrameAnalysis = false
        configureButton(transportBar.previous, symbol: "backward.end.fill", label: "Previous Photo", identifier: "previousPhoto", action: #selector(previousPhoto(_:)))
        configureButton(transportBar.playPause, symbol: "play.fill", label: "Play", identifier: "playPause", action: #selector(togglePlayback(_:)))
        configureButton(transportBar.next, symbol: "forward.end.fill", label: "Next Photo", identifier: "nextPhoto", action: #selector(nextPhoto(_:)))
        configureButton(transportBar.fullscreen, symbol: "arrow.up.left.and.arrow.down.right", label: "Enter Fullscreen", identifier: "toggleFullscreen", action: #selector(toggleFullscreen(_:)))
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updatePhotoControls() }
        controlsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearManualInput()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }; focusObservers = []
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        onWindowChanged?(window)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                self.revealPhotoControls()
                if event.type == .keyUp, self.liveSurface?.setManualKey(event.keyCode, pressed: false) == true { return nil }
                if event.type == .keyDown, self.handlePhotoKey(event) { return nil }
                if self.handleManualPointer(event) { return nil }
                return event
            }
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.clearManualInput()
            })
        }
    }
    deinit {
        controlsTimer?.invalidate(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    func clearManualInput() { cameraDragPoint = nil; liveSurface?.clearManualKeys() }

    // Route only gestures that start over the image, leaving the sidebar,
    // transport buttons, settings and album browser with their normal behavior.
    @discardableResult
    func handleManualPointer(_ event: NSEvent) -> Bool {
        if event.type == .leftMouseUp, cameraDragPoint != nil { cameraDragPoint = nil; return true }
        guard window?.attachedSheet == nil, canExplorePausedScene else { cameraDragPoint = nil; return false }
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDragged, let previous = cameraDragPoint {
            cameraDragPoint = point
            return liveSurface?.moveManualCamera(x: -(point.x-previous.x)/max(1,bounds.width)*4,
                                                  y: (point.y-previous.y)/max(1,bounds.height)*4) == true
        }
        guard bounds.contains(point),
              transportBar.isHidden || !transportBar.bounds.contains(transportBar.convert(event.locationInWindow, from: nil)) else { return false }
        if event.type == .leftMouseDown {
            window?.makeFirstResponder(self); cameraDragPoint = point
            return true
        }
        if event.type == .scrollWheel {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            return liveSurface?.moveManualCamera(x: -event.scrollingDeltaX*multiplier/max(1,bounds.width)*4,
                                                  y: event.scrollingDeltaY*multiplier/max(1,bounds.height)*4) == true
        }
        return false
    }
    private func configureButton(_ button: NSButton, symbol: String, label: String, identifier: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        button.imagePosition = .imageOnly; button.isBordered = false
        button.contentTintColor = .white; button.focusRingType = .none
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label); button.toolTip = label
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.target = self; button.action = action
    }
    private func revealPhotoControls() {
        lastActivity = CACurrentMediaTime()
        transportBar.setHidden(false)
        updatePhotoControls()
    }
    private func updatePhotoControls() {
        if CACurrentMediaTime() - lastActivity >= 2.5 { transportBar.setHidden(true) }
        let playing = playback?.isPlaying ?? (player?.rate != 0 && player != nil)
        if lastPlaying != playing {
            lastPlaying = playing
            transportBar.playPause.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
            transportBar.playPause.setAccessibilityLabel(playing ? "Pause" : "Play")
            transportBar.playPause.toolTip = playing ? "Pause" : "Play"
        }
        let enabled = playback?.hasCurrentItem ?? (player?.currentItem != nil)
        toolTip = canExplorePausedScene ? "Drag or scroll to explore · W/A/S/D move the camera · Space resumes" : nil
        for button in transportBar.buttons { button.isEnabled = enabled }
        transportBar.fullscreen.isEnabled = window != nil && (enabled || windowFullscreen)
    }
    @objc private func previousPhoto(_ sender: Any?) { clearManualInput(); playback?.previousPhoto(); revealPhotoControls() }
    @objc private func nextPhoto(_ sender: Any?) { clearManualInput(); playback?.nextPhoto(); revealPhotoControls() }
    @objc private func toggleFullscreen(_ sender: Any?) {
        window?.toggleFullScreen(nil)
        revealPhotoControls()
    }
    @objc private func togglePlayback(_ sender: Any?) {
        if let playback { playback.togglePlayback() }
        else if player?.rate == 0 { player?.play() } else { player?.pause() }
        revealPhotoControls()
    }
    @discardableResult
    func handlePhotoKey(_ event: NSEvent) -> Bool {
        guard window?.attachedSheet == nil, !(window?.firstResponder is NSTextView),
              !(window?.firstResponder is NSTextField),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if liveSurface?.setManualKey(event.keyCode, pressed: true) == true { return true }
        switch event.keyCode {
        case 123: previousPhoto(nil)
        case 124: nextPhoto(nil)
        case 49: togglePlayback(nil)
        case 53 where windowFullscreen: toggleFullscreen(nil)
        default: return false
        }
        return true
    }
    func bind(to playback: ContinuousPlayback) {
        guard self.playback !== playback else { return }
        self.playback?.onPlayerChanged = nil
        self.playback = playback
        player = playback.player
        playback.requiresDisplayReady = true
        playback.onPlayerChanged = { [weak self] player in self?.player = player; self?.updatePhotoControls() }
        videoHost.wantsLayer = true
        videoHost.layer?.backgroundColor = NSColor.black.cgColor
        if let overlay = contentOverlayView {
            videoHost.frame = overlay.bounds
            videoHost.autoresizingMask = [.width, .height]
            overlay.addSubview(videoHost)
            for layer in playback.videoLayers { videoHost.layer?.addSublayer(layer) }
            transportBar.removeFromSuperview()
            transportBar.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(transportBar, positioned: .above, relativeTo: videoHost)
            let width = transportBar.widthAnchor.constraint(equalToConstant: 296)
            let height = transportBar.heightAnchor.constraint(equalToConstant: 64)
            let bottom = transportBar.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -24)
            for constraint in [width, height, bottom] { constraint.priority = .defaultHigh }
            NSLayoutConstraint.activate([
                transportBar.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                transportBar.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor),
                transportBar.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor),
                transportBar.topAnchor.constraint(greaterThanOrEqualTo: overlay.topAnchor),
                transportBar.bottomAnchor.constraint(lessThanOrEqualTo: overlay.bottomAnchor),
                width, height, bottom
            ])
        }
        revealPhotoControls()
        layoutVideo()
    }
    func setRealtime(_ enabled: Bool, settings: LiveRenderSettings, fallbackClips: [URL: URL]) {
        guard let playback else { return }
        if enabled {
            if liveSurface == nil, let overlay = contentOverlayView {
                let surface = LivePlaybackSurface(frame: overlay.bounds)
                guard surface.available else { return }
                surface.autoresizingMask = [.width, .height]
                surface.onSceneLoaded = { [weak self] in self?.onSceneLoaded?($0) }
                surface.onFallback = { [weak self] in self?.onLiveFallback?($0) }
                surface.settings = settings
                surface.bind(playback)
                overlay.addSubview(surface, positioned: .below, relativeTo: transportBar)
                playback.videoLayers.forEach { $0.removeFromSuperlayer() }
                videoHost.isHidden = true; liveSurface = surface
            }
            liveSurface?.settings = settings; liveSurface?.fallbackClips = fallbackClips
        } else if let surface = liveSurface {
            surface.unbind(); surface.removeFromSuperview(); liveSurface = nil
            videoHost.isHidden = false
            playback.videoLayers.forEach { videoHost.layer?.addSublayer($0) }
        }
    }
    override func layout() { super.layout(); layoutVideo() }
    private func layoutVideo() {
        guard let playback else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for layer in playback.videoLayers {
            layer.frame = videoHost.bounds
            layer.backgroundColor = NSColor.black.cgColor
            layer.videoGravity = windowFullscreen && fillScreen ? .resizeAspectFill : .resizeAspect
        }
        CATransaction.commit()
    }
    func setPresentation(fullscreen: Bool, fillScreen: Bool = true) {
        guard windowFullscreen != fullscreen || self.fillScreen != fillScreen else { return }
        windowFullscreen = fullscreen; self.fillScreen = fillScreen
        let label = fullscreen ? "Exit Fullscreen" : "Enter Fullscreen"
        transportBar.fullscreen.image = NSImage(systemSymbolName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        transportBar.fullscreen.setAccessibilityLabel(label)
        transportBar.fullscreen.toolTip = label
        videoGravity = windowFullscreen && fillScreen ? .resizeAspectFill : .resizeAspect
        layoutVideo()
    }
    override func keyDown(with event: NSEvent) {
        revealPhotoControls()
        if handlePhotoKey(event) { return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if liveSurface?.setManualKey(event.keyCode, pressed: false) == true { return }
        super.keyUp(with: event)
    }
}

private final class SlideshowTransportBar: NSVisualEffectView {
    let previous = NSButton(), playPause = NSButton(), next = NSButton(), fullscreen = NSButton()
    var buttons: [NSButton] { [previous, playPause, next, fullscreen] }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("photoTransportBar")
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 18; layer?.masksToBounds = true
        for button in buttons { addSubview(button) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        setAccessibilityChildren(hidden ? [] : buttons)
        for button in buttons { button.setAccessibilityElement(!hidden) }
    }
    override func layout() {
        super.layout()
        let spacing = bounds.width / CGFloat(buttons.count)
        let width = max(0, min(52, spacing - 4)), height = min(48, bounds.height)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: spacing * (CGFloat(index) + 0.5) - width / 2,
                                  y: (bounds.height - height) / 2, width: width, height: height)
        }
    }
}

private final class SlideshowVideoHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // AVKit resizes its overlay after the parent player's layout callback.
    // Resize the retained layers with their actual host, including fullscreen.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeVideoLayers()
    }
    override func layout() {
        super.layout()
        resizeVideoLayers()
    }
    private func resizeVideoLayers() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for videoLayer in layer?.sublayers ?? [] { videoLayer.frame = bounds }
        CATransaction.commit()
    }
}
