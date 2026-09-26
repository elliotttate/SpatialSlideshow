import AVKit

final class SlideshowPlayerView: AVPlayerView {
    private weak var playback: ContinuousPlayback?
    private let videoHost = SlideshowVideoHost()
    private var fillScreen = true
    private var windowFullscreen = false
    private var keyMonitor: Any?
    private let transportBar = SlideshowTransportBar()
    private var controlsTimer: Timer?
    private var lastActivity = CACurrentMediaTime()
    private var lastPlaying: Bool?
    var arePhotoControlsVisible: Bool { !transportBar.isHidden }
    var onWindowChanged: ((NSWindow) -> Void)?

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
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        onWindowChanged?(window)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                self.revealPhotoControls()
                if event.type == .keyDown, self.handlePhotoKey(event) { return nil }
                return event
            }
        }
    }
    deinit { controlsTimer?.invalidate(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
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
        let enabled = player?.currentItem != nil
        for button in transportBar.buttons { button.isEnabled = enabled }
        transportBar.fullscreen.isEnabled = window != nil && (enabled || windowFullscreen)
    }
    @objc private func previousPhoto(_ sender: Any?) { playback?.previousPhoto(); revealPhotoControls() }
    @objc private func nextPhoto(_ sender: Any?) { playback?.nextPhoto(); revealPhotoControls() }
    @objc private func toggleFullscreen(_ sender: Any?) {
        window?.toggleFullScreen(nil)
        revealPhotoControls()
    }
    @objc private func togglePlayback(_ sender: Any?) {
        if let playback { playback.togglePlayback() }
        else if player?.rate == 0 { player?.play() } else { player?.pause() }
        revealPhotoControls()
    }
    private func handlePhotoKey(_ event: NSEvent) -> Bool {
        guard window?.attachedSheet == nil, !(window?.firstResponder is NSTextView),
              !(window?.firstResponder is NSTextField),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
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
