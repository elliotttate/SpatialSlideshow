import AVFoundation
import Darwin

@main
struct LiveTransportTest {
    static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    static func wait(_ description: String, timeout: Double = 3, until predicate: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < end { pump(0.01) }
        precondition(predicate(), description)
    }
    static func scene(_ number: Int) -> URL {
        URL(fileURLWithPath: "/synthetic-live-scene-\(number).splat")
    }
    static func currentSlot(_ playback: ContinuousPlayback) -> Int {
        playback.videoLayers.firstIndex { $0.player === playback.player }!
    }
    static func main() {
        setbuf(stdout, nil)
        let video = URL(fileURLWithPath: CommandLine.arguments[1])
        let playback = ContinuousPlayback()
        playback.usesExternalFrameClock = true
        // Exercise the public display clock rather than the engine's timer.
        let clock = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in playback.advanceFrame() }
        defer { clock.invalidate(); playback.stop() }
        playback.sceneDuration = 0.6
        playback.transitionDuration = 0.18
        playback.shuffleReplays = false
        var ready: Set<URL> = []
        var shown: [Int] = [], repeats = 0, finishes = 0, failures = 0
        playback.sceneIsReady = { _, url in ready.contains(url) }
        playback.onItem = { shown.append($0) }
        playback.onReplay = { shown.append($0) }
        playback.onRepeat = { _ in repeats += 1 }
        playback.onFinished = { finishes += 1 }
        playback.onFailure = { _ in failures += 1 }
        playback.begin()
        playback.appendScene(scene(0), number: 0)
        playback.appendScene(scene(1), number: 1)
        playback.finishPreparing()
        pump(0.2)
        precondition(playback.hasCurrentItem && playback.player.currentItem == nil, "A scene is a retained playable item without a dummy video")
        precondition(playback.sceneProgress == [0, 0], "Loading does not consume scene duration")
        ready.insert(scene(0)); ready.insert(scene(1))
        pump(0.15)
        let slot = currentSlot(playback)
        precondition(playback.sceneProgress[slot] > 0.1, "Ready scenes animate on the display clock")
        precondition(playback.sceneProgress[1 - slot] == 0, "Preloading cannot consume the incoming scene's duration")
        wait("Two ready scenes must crossfade") { playback.isTransitioning && playback.transitionFraction > 0.1 }
        playback.togglePlayback()
        let fraction = playback.transitionFraction, positions = playback.sceneProgress
        pump(0.15)
        precondition(playback.transitionFraction == fraction && playback.sceneProgress == positions, "Pause freezes both scenes and the fade")
        playback.togglePlayback()
        wait("All prepared scenes must finish once") { finishes == 1 }
        precondition(shown == [0, 1] && playback.hasCurrentItem && !playback.isPlaying, "Scene completion retains the final image")
        print("LIVE_CLOCK_SUCCESS readiness, preload, display clock, fade, pause and completion")

        playback.begin(); ready = [scene(2)]
        playback.sceneDuration = 0.25; playback.transitionDuration = 0.06
        shown = []; repeats = 0
        playback.appendScene(scene(2), number: 2)
        playback.appendScene(scene(3), number: 3)
        let generation = playback.sceneGeneration[currentSlot(playback)]
        pump(0.7)
        precondition(repeats >= 2 && shown == [2], "Repeat the visible scene while its successor is loading")
        precondition(playback.sceneGeneration[currentSlot(playback)] > generation, "Repeated scenes get a new motion generation")
        precondition(playback.sceneProgress[1 - currentSlot(playback)] == 0, "An unready successor remains at its first frame")
        ready.insert(scene(3))
        wait("A late ready successor must advance") { shown.contains(3) }
        playback.stop()
        precondition(playback.sceneURLs == [nil, nil] && !playback.hasCurrentItem, "Stop releases both virtual scene slots")
        print("LIVE_WAIT_SUCCESS repeated current scene then late successor")

        playback.begin(); shown = []; ready = Set((10...14).map(scene))
        playback.addPreparedScenes((10...13).map { (scene($0), $0) })
        wait("Every available unseen scene must precede any repeat") { shown.count >= 4 }
        precondition(shown.prefix(4) == [10, 11, 12, 13], "Cached live scenes must preserve unseen-photo priority")
        playback.appendScene(scene(14), number: 14)
        wait("A newly prepared scene preempts speculative replay") { shown.count >= 5 }
        precondition(shown[4] == 14, "A just-prepared unseen scene should not wait behind a repeat")
        playback.togglePlayback()
        let beforeNavigation = playback.displayedNumber
        playback.previousPhoto()
        wait("Previous navigates while paused") { playback.displayedNumber == 13 }
        precondition(!playback.isPlaying && playback.sceneProgress[currentSlot(playback)] == 0, "Paused navigation shows the destination's first frame")
        playback.nextPhoto()
        wait("Next returns through browsing history") { playback.displayedNumber == beforeNavigation }
        precondition(!playback.isPlaying, "Navigation must preserve pause")
        print("LIVE_ORDER_SUCCESS cache fairness, unseen priority and paused history navigation")

        playback.begin(); shown = []; ready = [scene(20), scene(22)]
        playback.appendScene(scene(20), number: 20)
        playback.append(video, number: 21)
        playback.appendScene(scene(22), number: 22)
        playback.finishPreparing()
        wait("Scenes can transition into a real video") { playback.displayedNumber == 21 }
        precondition(playback.player.currentItem != nil && playback.sceneURLs[currentSlot(playback)] == nil, "Video transport uses a real player slot")
        wait("Videos can transition back to scenes", timeout: 5) { playback.displayedNumber == 22 }
        precondition(playback.player.currentItem == nil && playback.hasCurrentItem, "Returning to a scene must not fabricate an AV item")
        print("LIVE_MIXED_SUCCESS scene to video to scene")

        playback.begin(); shown = []; ready = [scene(30)]
        playback.appendScene(scene(30), number: 30)
        playback.appendScene(scene(31), number: 31)
        playback.replaceSceneWithClip(sceneURL: scene(31), clipURL: video)
        wait("A failed incoming scene may use its prepared clip") { playback.displayedNumber == 31 }
        precondition(playback.player.currentItem != nil, "Fallback uses the existing clip")
        precondition(shown == [30, 31], "Fallback preserves original photo identity and viewing order")
        playback.togglePlayback()
        playback.previousPhoto()
        wait("Can navigate back from a clip fallback") { playback.displayedNumber == 30 }
        playback.replaceSceneWithClip(sceneURL: scene(30), clipURL: video)
        precondition(playback.player.currentItem != nil && !playback.isPlaying, "Current-scene fallback preserves pause")
        print("LIVE_FALLBACK_SUCCESS incoming/current replacement and pause")

        playback.begin(); shown = []; failures = 0; ready = [scene(40), scene(42)]
        playback.appendScene(scene(40), number: 40)
        playback.appendScene(scene(41), number: 41)
        playback.appendScene(scene(42), number: 42)
        let incomingSlot = 1 - currentSlot(playback)
        playback.sceneFailed(slot: incomingSlot, url: scene(41), error: NSError(domain: "SyntheticScene", code: 1))
        playback.sceneFailed(slot: incomingSlot, url: scene(41), error: NSError(domain: "SyntheticScene", code: 1))
        wait("A corrupt incoming scene must be skipped") { playback.displayedNumber == 42 }
        precondition(failures == 1 && shown == [40, 42], "Duplicate/stale failures cannot discard another scene")
        playback.begin(); shown = []; failures = 0; ready = [scene(51)]
        playback.appendScene(scene(50), number: 50)
        playback.appendScene(scene(51), number: 51)
        playback.sceneFailed(slot: currentSlot(playback), url: scene(50), error: NSError(domain: "SyntheticScene", code: 2))
        wait("A failed startup scene must advance to a ready successor") { playback.displayedNumber == 51 }
        precondition(failures == 1, "Failed startup scene is reported once")
        print("PASS live scene transport, readiness, mixed video, fades, pause, navigation, fairness and fallback")
    }
}
