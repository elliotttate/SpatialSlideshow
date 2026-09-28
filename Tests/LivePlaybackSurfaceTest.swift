import AppKit
import AVKit
import MetalKit

/// Synthetic splat scenes exercise the actual Apple Gaussian renderer and the
/// production Metal view together, without model inference or personal photos.
@main
struct LivePlaybackSurfaceTest {
    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func scene(at directory: URL, blue: Bool) throws {
        let manager = FileManager.default, grid = 64
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values: [String: [Float16]] = ["alphas": [], "positions": [], "scales": [], "rotations": [], "colors": []]
        for plane in 0..<2 {
            for y in 0..<grid {
                for x in 0..<grid {
                    let z: Float = plane == 0 ? 2 : 3
                    let px = (Float(x) / Float(grid - 1) * 2 - 1) * z * 1.78
                    let py = (Float(y) / Float(grid - 1) * 2 - 1) * z
                    let checker = (x / 6 + y / 6) % 2 == 0
                    values["positions"]! += [Float16(px), Float16(py), Float16(z)]
                    values["scales"]! += [0.06, 0.06, 0.02]
                    values["rotations"]! += [1, 0, 0, 0]
                    values["alphas"]!.append(plane == 0 ? 0.82 : 1)
                    let major: Float16 = checker ? 0.95 : 0.35
                    let minor: Float16 = checker ? 0.2 : 0.03
                    values["colors"]! += blue ? [minor, 0.1, major] : [major, 0.1, minor]
                }
            }
        }
        var metadata: [String: Any] = [:]
        for (name, buffer) in values {
            let packed = buffer.map { $0.bitPattern.littleEndian }
            let data = packed.withUnsafeBytes { Data($0) }
            try data.write(to: directory.appendingPathComponent(name + ".bin"))
            metadata[name] = ["width": 64, "height": buffer.count / 64, "bytesPerRow": 128, "pixelFormat": 1_278_226_536]
        }
        let manifest: [String: Any] = ["width": 640, "height": 360, "buffers": metadata]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("scene.json"))
    }

    static func pixels(_ image: CGImage?) -> [Double]? {
        guard let image else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        var result: [Double] = []
        // Sample across the image rather than only at a possibly black pixel.
        for y in 1..<10 {
            for x in 1..<17 {
                guard let color = bitmap.colorAt(x: bitmap.pixelsWide * x / 18, y: bitmap.pixelsHigh * y / 11)?.usingColorSpace(.deviceRGB) else { return nil }
                result += [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
            }
        }
        return result
    }

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        precondition(LiveGaussianScene.isAvailable(), "Apple's Gaussian renderer is required for the live surface test")
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SpatialLiveSurfaceTest-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let first = root.appendingPathComponent("red"), second = root.appendingPathComponent("blue")
        try scene(at: first, blue: false); try scene(at: second, blue: true)
        precondition(SceneCache.validateScene(first) && SceneCache.validateScene(second))
        let broken = root.appendingPathComponent("broken")
        try manager.createDirectory(at: broken, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("video.mp4"), fallback = root.appendingPathComponent("fallback.mp4")
        try manager.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: video)
        try manager.copyItem(at: video, to: fallback)
        let surface = LivePlaybackSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        precondition(surface.available)
        surface.settings = LiveRenderSettings(seconds: 3, strength: 2, pattern: 0, zoomOut: 0, longEdge: 1280)
        surface.fallbackClips[broken] = fallback
        let window = NSWindow(contentRect: surface.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface; window.orderFrontRegardless()
        let playback = ContinuousPlayback()
        playback.shuffleReplays = false; playback.transitionDuration = 0.6; playback.audioEnabled = false
        var failures: [String] = [], fallbacks: [String] = [], transitions = 0
        playback.onFailure = { failures.append($0.localizedDescription) }
        surface.onFallback = { fallbacks.append($0) }
        playback.onTransition = { _, _, _ in transitions += 1 }
        surface.bind(playback)
        defer { playback.stop(); surface.unbind(); window.close() }
        playback.begin()
        playback.appendScene(first, number: 0)
        playback.appendScene(second, number: 1)
        playback.append(video, number: 2)
        playback.appendScene(broken, number: 3)
        // Leave production open, as screen-saver playback does, so completed
        // items cycle while more photos could still become ready.
        let readyDeadline = Date().addingTimeInterval(10)
        while (playback.sceneProgress.max() ?? 0) < 0.08 && Date() < readyDeadline { pump(0.025) }
        guard let before = pixels(surface.snapshot()) else { preconditionFailure("No GPU scene snapshot") }
        precondition((before.max() ?? 0) > 0.1, "The first synthetic scene must render visible pixels")
        pump(0.55)
        guard let after = pixels(surface.snapshot()) else { preconditionFailure("No moving scene snapshot") }
        let movement = zip(before, after).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(before.count)
        precondition(movement > 0.001, "Live camera motion must change rendered pixels: \(movement)")
        playback.togglePlayback()
        pump(0.1)
        let pausedProgress = playback.sceneProgress
        let pausedRenders = surface.sceneRenderCount
        pump(0.35)
        precondition(!playback.isPlaying && playback.sceneProgress == pausedProgress, "Pausing must stop the live camera timeline")
        precondition(surface.sceneRenderCount == pausedRenders, "Paused scenes reuse their last GPU frame instead of rendering splats repeatedly")
        let beforeExplore = pixels(surface.snapshot())!
        precondition(surface.canExplore && surface.moveManualCamera(x: 0.65, y: -0.35))
        pump(0.6)
        let explored = pixels(surface.snapshot())!
        let exploreChange = zip(beforeExplore, explored).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(explored.count)
        precondition(exploreChange > 0.001 && playback.sceneProgress == pausedProgress && !playback.isPlaying,
                     "Manual exploration must change real Gaussian pixels without advancing playback: \(exploreChange)")
        let restingRenders = surface.sceneRenderCount
        pump(0.25)
        precondition(surface.sceneRenderCount == restingRenders, "Released exploration must settle back to frame reuse")
        let beforeTap = surface.manualCameraOffset.y
        precondition(surface.setManualKey(13, pressed: true))
        precondition(surface.setManualKey(13, pressed: false))
        pump(0.5)
        precondition(surface.manualCameraOffset.y < beforeTap - 0.05, "A quick WASD tap must move even between display frames")
        precondition(surface.setManualKey(2, pressed: true))
        pump(0.3)
        precondition(surface.setManualKey(2, pressed: false))
        pump(0.6)
        precondition(surface.manualCameraOffset.x > 0.9 && surface.manualCameraOffset.x <= 1,
                     "Held D must move continuously and remain bounded")
        playback.togglePlayback(); pump(0.03)
        precondition(surface.manualCameraOffset.x > 0.1, "Resume must ease back instead of snapping to the path")
        precondition(!surface.moveManualCamera(x: 1, y: 1) && !surface.setManualKey(13, pressed: true),
                     "Manual control only applies while paused")
        pump(0.95)
        precondition(abs(surface.manualCameraOffset.x) < 0.001 && abs(surface.manualCameraOffset.y) < 0.001,
                     "Resuming must return to the automatic camera")
        playback.togglePlayback(); pump(0.05)
        precondition(surface.moveManualCamera(x: 0.4, y: 0.3))
        pump(0.2)
        playback.nextPhoto()
        let nextDeadline = Date().addingTimeInterval(5)
        while playback.displayedNumber != 1 && Date() < nextDeadline { pump(0.025) }
        precondition(playback.displayedNumber == 1 && !playback.isPlaying, "Next navigates while remaining paused")
        pump(0.1)
        precondition(surface.manualCameraOffset == .zero, "Manual camera offset must reset on photo changes")
        playback.previousPhoto()
        let previousDeadline = Date().addingTimeInterval(5)
        while playback.displayedNumber != 0 && Date() < previousDeadline { pump(0.025) }
        precondition(playback.displayedNumber == 0 && !playback.isPlaying, "Previous returns to the prior scene while paused")
        playback.togglePlayback()

        var visits = Set<Int>(), samples = 0, black = 0, fadeSamples = 0
        let firstFrame = surface.renderedFrameCount
        let started = Date(), deadline = started.addingTimeInterval(14)
        while Date() < deadline {
            pump(0.04)
            if let number = playback.displayedNumber { visits.insert(number) }
            if playback.isTransitioning && playback.transitionFraction > 0 && playback.transitionFraction < 1 { fadeSamples += 1 }
            if let sampled = pixels(surface.snapshot()) {
                samples += 1
                if (sampled.max() ?? 0) < 0.05 { black += 1 }
            }
        }
        let frames = surface.renderedFrameCount - firstFrame, elapsed = Date().timeIntervalSince(started)
        print("LIVE SURFACE frames=\(frames) fps=\(Double(frames) / elapsed) samples=\(samples) black=\(black) fadeSamples=\(fadeSamples) transitions=\(transitions) visits=\(visits.sorted()) movement=\(movement) fallbacks=\(fallbacks.count) failures=\(failures)")
        precondition(visits == Set([0, 1, 2, 3]), "Both live scenes, video and fallback must all play: \(visits)")
        precondition(!fallbacks.isEmpty && failures.isEmpty, "Broken scene must use its prepared clip without stopping: \(failures)")
        precondition(transitions >= 4 && fadeSamples >= 10, "The GPU surface must compose fades across live scenes and clips")
        precondition(samples > 100 && black == 0, "After loading, composed output must remain visible across movement and transitions")
        precondition(frames > 300, "GPU drawing must continue at interactive cadence, not only at item changes")
        // Current-scene fallback must hold the last image while AVFoundation
        // decodes, including while paused.
        playback.begin(); playback.appendScene(first, number: 10)
        let restartDeadline = Date().addingTimeInterval(5)
        while (playback.sceneProgress.max() ?? 0) < 0.1 && Date() < restartDeadline { pump(0.025) }
        playback.togglePlayback(); pump(0.1)
        playback.replaceSceneWithClip(sceneURL: first, clipURL: video)
        for _ in 0..<20 {
            pump(0.02)
            precondition((pixels(surface.snapshot())?.max() ?? 0) > 0.05, "Current-scene fallback must hold a visible frame")
        }
        // Paused video-to-video navigation has no scene URL changes. Its image
        // cache must track decoded frames and transport identity too.
        if CommandLine.arguments.count > 2 {
            playback.begin(); playback.transitionDuration = 0
            playback.append(video, number: 20)
            playback.append(URL(fileURLWithPath: CommandLine.arguments[2]), number: 21)
            pump(0.4); playback.togglePlayback(); pump(0.1)
            let old = pixels(surface.snapshot())!
            playback.nextPhoto(); pump(0.5)
            let new = pixels(surface.snapshot())!
            let change = zip(old, new).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(old.count)
            precondition(playback.displayedNumber == 21 && !playback.isPlaying && change > 0.05,
                         "Paused video navigation must display the new decoded image")
        }
        // Exercise production input routing without synthesizing system input.
        playback.stop(); surface.unbind(); window.orderOut(nil)
        let inputPlayback = ContinuousPlayback()
        let inputView = SlideshowPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let inputWindow = NSWindow(contentRect: inputView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        inputWindow.isReleasedWhenClosed = false; inputWindow.contentView = inputView
        inputView.bind(to: inputPlayback)
        inputView.setRealtime(true, settings: LiveRenderSettings(seconds: 10, strength: 2, pattern: 0, zoomOut: 0, longEdge: 1280), fallbackClips: [:])
        inputWindow.orderBack(nil); inputView.layoutSubtreeIfNeeded()
        inputPlayback.begin(); inputPlayback.appendScene(first, number: 0)
        let inputDeadline = Date().addingTimeInterval(5)
        while (inputPlayback.sceneProgress.max() ?? 0) < 0.02 && Date() < inputDeadline { pump(0.025) }
        inputPlayback.togglePlayback(); pump(0.1)
        precondition(inputView.canExplorePausedScene)
        func key(_ code: UInt16, _ character: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: inputWindow.windowNumber, context: nil, characters: character,
                            charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        precondition(inputView.handlePhotoKey(key(13, "w")))
        pump(0.25); inputView.clearManualInput(); pump(0.6)
        precondition(inputView.manualCameraOffset.y < -0.2, "W must move the paused camera upwards")
        let stoppedOffset = inputView.manualCameraOffset
        pump(0.2)
        precondition(inputView.manualCameraOffset == stoppedOffset, "Focus loss must stop held-key movement")
        precondition(!inputView.handlePhotoKey(key(0, "a", modifiers: .command)), "App shortcuts must not move the camera")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        inputView.addSubview(editor); inputWindow.makeFirstResponder(editor)
        precondition(!inputView.handlePhotoKey(key(2, "d")), "Typing must not move the camera")
        editor.removeFromSuperview(); inputWindow.makeFirstResponder(inputView)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: inputView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                              windowNumber: inputWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        precondition(inputView.handleManualPointer(mouse(.leftMouseDown, NSPoint(x: 250, y: 200))))
        precondition(inputView.handleManualPointer(mouse(.leftMouseDragged, NSPoint(x: 330, y: 225))))
        precondition(inputView.handleManualPointer(mouse(.leftMouseUp, NSPoint(x: 330, y: 225))))
        pump(0.6)
        precondition(inputView.manualCameraOffset.x < -0.3, "Dragging the image must move its 3D camera")
        func findBar(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "photoTransportBar" { return view }
            return view.subviews.lazy.compactMap { findBar($0) }.first
        }
        let bar = findBar(inputView)!
        let buttonPoint = inputView.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY), from: bar)
        precondition(!inputView.handleManualPointer(mouse(.leftMouseDown, buttonPoint)), "Transport clicks must not start camera drags")
        inputPlayback.stop(); inputView.setRealtime(false, settings: LiveRenderSettings(), fallbackClips: [:]); inputWindow.orderOut(nil)
        print("PASS live Gaussian motion, manual camera pixels/input/focus/bounds/resume, pause/navigation, GPU fades, mixed media and failed-scene clip fallback")
    }
}
