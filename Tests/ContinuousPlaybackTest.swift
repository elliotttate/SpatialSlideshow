import AVFoundation
import Darwin

@main
struct ContinuousPlaybackTest {
    static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    static func main() {
        setbuf(stdout, nil)
        let clip = URL(fileURLWithPath: CommandLine.arguments[1])
        let playback = ContinuousPlayback()
        playback.transitionDuration = 0.25
        var items: [Int] = [], repeats = 0, finishes = 0
        playback.onItem = { items.append($0); print("ITEM", $0) }
        playback.onRepeat = { repeats += 1; print("REPEAT", $0) }
        playback.onFinished = { finishes += 1; print("FINISHED") }
        playback.begin(); playback.append(clip, number: 0)
        var emptySamples = 0, frameSamples = 0, darkFrames = 0, dissolveSamples = 0
        var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
        let monitor = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if playback.isTransitioning && playback.transitionFraction > 0 && playback.transitionFraction < 1 { dissolveSamples += 1 }
            guard let item = playback.player.currentItem else { emptySamples += 1; return }
            let key = ObjectIdentifier(item)
            if outputs[key] == nil {
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output); outputs[key] = output
            }
            guard let output = outputs[key], let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) else { return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            var total = 0
            for y in Swift.stride(from: height/4, to: 3*height/4, by: 8) {
                for x in Swift.stride(from: width/4, to: 3*width/4, by: 8) { total += Int(bytes[y*stride+x*4+1]) }
            }
            if total == 0 { darkFrames += 1 }
            frameSamples += 1
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        pump(3.3)
        precondition(repeats >= 2, "Must repeat while the next photo is missing")
        playback.append(clip, number: 1); playback.finishPreparing()
        pump(3)
        print("DELAYED_METRICS", "items=\(items)", "finishes=\(finishes)", "retained=\(playback.player.currentItem != nil)", "rate=\(playback.player.rate)", "frames=\(frameSamples)", "empty=\(emptySamples)", "black=\(darkFrames)", "dissolve=\(dissolveSamples)")
        precondition(items == [0, 1] && finishes == 1, "Late photo must advance and finish once")
        precondition(playback.player.currentItem != nil && playback.player.rate == 0, "Final photo must stay visible")
        precondition(emptySamples == 0 && darkFrames == 0 && frameSamples > 30, "No empty player or black decoded frames")
        precondition(dissolveSamples > 2, "Ready successor must visibly dissolve across multiple frames")
        monitor.invalidate()
        print("DELAYED_SUCCESS", "repeats=\(repeats)", "frameSamples=\(frameSamples)", "empty=\(emptySamples)", "black=\(darkFrames)", "dissolveSamples=\(dissolveSamples)")

        playback.begin(); playback.append(clip, number: 2); pump(0.3)
        playback.player.pause(); playback.append(clip, number: 3); pump(0.3)
        precondition(playback.player.rate == 0, "Appending must preserve user pause")
        playback.stop(); playback.append(clip, number: 4); pump(0.2)
        precondition(playback.player.currentItem == nil && playback.player.rate == 0, "Cancelled work cannot restart playback")

        playback.begin(); playback.append(clip, number: 6); playback.append(clip, number: 7)
        let deadline = Date().addingTimeInterval(3)
        while !playback.isTransitioning && Date() < deadline { pump(0.02) }
        precondition(playback.isTransitioning, "Must start optional dissolve")
        playback.togglePlayback(); pump(0.05)
        let pausedFraction = playback.transitionFraction
        pump(0.2)
        precondition(playback.transitionFraction == pausedFraction, "Pause must freeze both sides of dissolve")
        precondition(playback.videoLayers.allSatisfy { $0.player?.rate == 0 }, "Both players must pause")
        playback.togglePlayback(); playback.stop(); pump(0.3)
        precondition(playback.videoLayers.allSatisfy { $0.player?.currentItem == nil && $0.player?.rate == 0 }, "Stopping a dissolve must not restart either player")
        print("DISSOLVE_SUCCESS pause and cancellation")

        // A late decoded successor must not shorten the configured fade. The
        // outgoing final frame stays visible while the full dissolve completes.
        playback.transitionDuration = 0.3
        playback.requiresDisplayReady = true
        var allowIncoming = false
        playback.frameIsReady = { layer in layer.player === playback.player || allowIncoming }
        playback.begin(); playback.append(clip, number: 20); playback.append(clip, number: 21)
        let lateDeadline = Date().addingTimeInterval(5)
        while playback.player.currentTime().seconds < 0.93 && Date() < lateDeadline { pump(0.002) }
        precondition(playback.player.currentTime().seconds >= 0.93 && !playback.isTransitioning, "Hold successor readiness until the last part of the clip")
        allowIncoming = true
        while !playback.isTransitioning && Date() < lateDeadline { pump(0.002) }
        precondition(playback.isTransitioning, "Late successor must start a fade")
        let lateStarted = CACurrentMediaTime()
        while playback.isTransitioning && Date() < lateDeadline { pump(0.002) }
        let lateDuration = CACurrentMediaTime() - lateStarted
        precondition(playback.displayedNumber == 21 && lateDuration >= 0.25, "Late readiness must preserve the full fade")
        playback.stop(); playback.frameIsReady = nil; playback.requiresDisplayReady = false
        print("LATE_DISSOLVE_SUCCESS", lateDuration)

        playback.transitionDuration = 0
        items = []; finishes = 0
        playback.begin(); playback.append(clip, number: 8); playback.append(clip, number: 9); playback.finishPreparing(); pump(2.7)
        precondition(items == [8, 9] && finishes == 1 && playback.player.currentItem != nil, "Cuts must advance and retain the final frame")
        print("CUT_SUCCESS")

        repeats = 0
        playback.begin(loopMovie: true); playback.append(clip, number: 10); pump(0.2)
        playback.begin(loopMovie: true); playback.append(clip, number: 11); pump(1.4)
        precondition(repeats >= 1 && playback.player.rate > 0, "A new session must ignore queued pause events from the old session")
        print("RESTART_SUCCESS stale transport events ignored")

        repeats = 0
        playback.begin(loopMovie: true); playback.append(clip, number: 5); playback.finishPreparing(); pump(2.4)
        precondition(repeats >= 2 && playback.player.currentItem != nil, "Movie must keep looping")
        playback.onRepeat = { _ in playback.stop() }
        pump(1.2)
        precondition(playback.player.currentItem == nil && playback.player.rate == 0, "Cancellation during rewind must not restart playback")
        playback.stop()
        items = []; var failedItems = 0
        playback.onItem = { items.append($0) }; playback.onFailure = { _ in failedItems += 1 }
        playback.onRepeat = { _ in }
        playback.begin()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).mp4")
        playback.addPreparedReplays([(missing, 99)])
        playback.append(clip, number: 100)
        pump(2)
        precondition(failedItems == 1 && items == [100], "Bad startup cache reports one failure and advances to valid item")
        playback.stop()
        print("PASS delayed successor, frame retention, pause, looping, cancellation and failed startup cache")
    }
}
