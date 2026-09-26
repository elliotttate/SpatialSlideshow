import AppKit
import AVKit
import Darwin

private final class FullscreenTestWindow: NSWindow {
    var fullscreenToggleCount = 0
    override func toggleFullScreen(_ sender: Any?) { fullscreenToggleCount += 1 }
}

@main
enum FullscreenControlsTest {
    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func wait(_ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(4)
        while !predicate() && Date() < end { pump(0.01) }
        return predicate()
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let window = FullscreenTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let playback = ContinuousPlayback()
        let view = SlideshowPlayerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        window.contentView = view; view.bind(to: playback); window.orderBack(nil); view.layoutSubtreeIfNeeded(); pump(0.1)
        var checks: [String: Bool] = [:]
        func expect(_ condition: Bool, _ description: String) {
            checks[description] = condition; print(condition ? "PASS" : "FAIL", description)
        }
        func hasGravity(_ gravity: AVLayerVideoGravity) -> Bool {
            view.videoGravity == gravity && playback.videoLayers.allSatisfy { $0.videoGravity == gravity }
        }
        guard let bar = descendants(view).first(where: { $0.identifier?.rawValue == "photoTransportBar" }) as? NSVisualEffectView,
              let previous = bar.subviews.first(where: { $0.identifier?.rawValue == "previousPhoto" }) as? NSButton,
              let playPause = bar.subviews.first(where: { $0.identifier?.rawValue == "playPause" }) as? NSButton,
              let next = bar.subviews.first(where: { $0.identifier?.rawValue == "nextPhoto" }) as? NSButton,
              let fullscreen = bar.subviews.first(where: { $0.identifier?.rawValue == "toggleFullscreen" }) as? NSButton,
              let overlay = view.contentOverlayView else { fatalError("Custom photo bar is missing") }
        expect(view.controlsStyle == .none, "native controls are disabled")
        expect(!view.showsFullScreenToggleButton && !view.allowsPictureInPicturePlayback, "one owning window retains video layers")
        expect(bar.subviews.compactMap { $0 as? NSButton }.count == 4, "single rounded background contains four playback and fullscreen buttons")
        expect(previous.accessibilityLabel() == "Previous Photo" && playPause.accessibilityLabel() == "Play" && next.accessibilityLabel() == "Next Photo", "buttons have photo navigation accessibility labels")
        expect([previous, playPause, next, fullscreen].allSatisfy { $0.accessibilityRole() == .button }, "photo controls expose button accessibility roles")
        expect(fullscreen.accessibilityLabel() == "Enter Fullscreen" && fullscreen.toolTip == "Enter Fullscreen" && fullscreen.image != nil, "windowed fullscreen button has enter icon and help")
        expect(view.actionPopUpButtonMenu == nil, "native action menu is absent")
        expect(bar.frame.width == 296 && bar.frame.height == 64 && overlay.bounds.contains(bar.frame), "compact transport bar is inside player bounds")
        view.setPresentation(fullscreen: true, fillScreen: true)
        expect(fullscreen.accessibilityLabel() == "Exit Fullscreen" && fullscreen.toolTip == "Exit Fullscreen" && fullscreen.image != nil, "fullscreen button changes to exit icon and help")
        expect(hasGravity(.resizeAspectFill), "fullscreen fill applies to both layers")
        for size in [NSSize(width: 1728, height: 1117), NSSize(width: 800, height: 650), NSSize(width: 120, height: 60)] {
            overlay.setFrameSize(size); overlay.layoutSubtreeIfNeeded()
            expect(playback.videoLayers.allSatisfy { $0.frame.size == overlay.bounds.size }, "video layers follow overlay size \(Int(size.width))x\(Int(size.height))")
            expect(overlay.bounds.contains(bar.frame), "transport bar stays in bounds at \(Int(size.width))x\(Int(size.height))")
        }
        overlay.setFrameSize(view.bounds.size); overlay.layoutSubtreeIfNeeded()
        view.setPresentation(fullscreen: true, fillScreen: false)
        expect(hasGravity(.resizeAspect), "fullscreen fit applies to both layers")
        view.setPresentation(fullscreen: false, fillScreen: true)
        expect(hasGravity(.resizeAspect) && view.controlsStyle == .none, "windowed mode keeps native panel disabled")

        var playingCallbacks = 0
        playback.onPlayingChanged = { _ in playingCallbacks += 1 }
        guard CommandLine.arguments.count > 2 else { fatalError("Supply a synthetic control-test video path") }
        let clipPath = CommandLine.arguments[2]
        let clip = URL(fileURLWithPath: clipPath)
        playback.begin(); playback.append(clip, number: 0); playback.append(clip, number: 1); playback.finishPreparing()
        expect(wait { playback.videoLayers.allSatisfy(\.isReadyForDisplay) }, "real video layers are ready before button testing")
        pump(0.15)
        expect(playPause.accessibilityLabel() == "Pause", "play button reflects current transport without owning callbacks")
        fullscreen.performClick(nil)
        expect(window.fullscreenToggleCount == 1 && playback.isPlaying, "fullscreen button uses owning window without changing playback")
        view.setPresentation(fullscreen: true)
        fullscreen.performClick(nil)
        expect(window.fullscreenToggleCount == 2, "same fullscreen button toggles the owning window to exit")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        expect(window.fullscreenToggleCount == 3 && view.controlsStyle == .none, "escape shares fullscreen route and leaves native transport disabled")
        view.setPresentation(fullscreen: false)
        playPause.performClick(nil); pump(0.1)
        expect(!playback.isPlaying && playback.player.rate == 0 && playPause.accessibilityLabel() == "Play", "play pause button pauses playback")
        next.performClick(nil)
        expect(wait { playback.displayedNumber == 1 && !playback.isTransitioning }, "next button navigates to next photo")
        expect(playback.player.rate == 0, "next button preserves pause")
        previous.performClick(nil)
        expect(wait { playback.displayedNumber == 0 && !playback.isTransitioning }, "previous button navigates to prior photo")
        playPause.performClick(nil); pump(0.1)
        expect(playback.isPlaying && playback.player.rate > 0, "play pause button resumes playback")
        expect(playingCallbacks >= 4, "application playing callback remains installed")
        pump(2.7)
        expect(bar.isHidden && !view.arePhotoControlsVisible, "idle hides the whole transport background")
        expect(bar.subviews.allSatisfy(\.isHiddenOrHasHiddenAncestor), "idle hides all transport buttons together")
        expect((bar.accessibilityChildren() ?? []).isEmpty && [previous, playPause, next, fullscreen].allSatisfy { !$0.isAccessibilityElement() }, "hidden controls are absent from accessibility")
        expect(bar.hitTest(NSPoint(x: bar.frame.midX, y: bar.frame.midY)) == nil, "hidden background is not hit testable")
        expect(view.controlsStyle == .none, "idle does not recreate a native panel")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        view.keyDown(with: event); pump(0.1)
        expect(!bar.isHidden && view.arePhotoControlsVisible && !playback.isPlaying, "space reveals the whole bar and toggles playback")
        expect((bar.accessibilityChildren() ?? []).count == 4, "revealed controls restore accessibility")
        expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) } && !NSApp.isActive, "test window remains offscreen and inactive")
        let passed = checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["passed": passed, "checks": checks,
            "scope": "Offscreen SlideshowPlayerView using a synthetic color video; button actions, retained layer readiness, visibility, bounds and accessibility. The test window intercepts fullscreen toggles; actual macOS fullscreen transitions require a live app check.",
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        playback.stop(); window.close()
        print("\(passed ? "PASS" : "FAIL"): \(checks.count) fullscreen and transport checks")
        exit(passed ? 0 : 1)
    }
}
