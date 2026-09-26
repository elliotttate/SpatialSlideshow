import AppKit
import Foundation

@main
enum MusicPlaybackTest {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let first = folder.appendingPathComponent("tone1.wav")
        let second = folder.appendingPathComponent("tone2.wav")
        let invalid = folder.appendingPathComponent("invalid.mp3")
        let suite = "SpatialSlideshow.MusicTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError("FAIL: \(description)") }
            checks.append(description)
        }
        func advance(_ seconds: TimeInterval, sample: (() -> Void)? = nil) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                sample?()
            }
        }
        func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { advance(0.01) }
            return condition()
        }
        let music = MusicPlayback(defaults: defaults)
        music.volume = 0 // Exercise real decoding and delegate callbacks silently.
        expect(music.loopPlaylist, "repeat defaults to enabled")
        music.replacePlaylist([first, second])
        music.startIfSelected()
        expect(music.isPlaying, "local audio starts")
        music.pause()
        advance(0.4)
        expect(!music.isPlaying && music.currentIndex == 0, "pause holds the track")
        music.startIfSelected()
        expect(waitUntil { music.isPlaying && music.currentIndex == 1 }, "natural completion advances the playlist")
        var observed = [music.currentIndex]
        advance(1.5) {
            if observed.last != music.currentIndex { observed.append(music.currentIndex) }
        }
        expect(observed.starts(with: [1, 0, 1]), "repeat wraps from the last track to the first")
        music.stop()
        expect(!music.isPlaying && music.currentIndex == 0, "stop rewinds the playlist")
        music.nextTrack()
        expect(!music.isPlaying && music.currentIndex == 1, "next while paused stays paused")
        music.stop()
        music.loopPlaylist = false
        music.startIfSelected()
        expect(waitUntil { !music.isPlaying && music.currentIndex == 1 }, "repeat off stops after the last track")
        music.startIfSelected()
        expect(music.isPlaying && music.currentIndex == 0, "play after completion restarts the playlist")
        music.replacePlaylist([invalid, second])
        expect(music.isPlaying && music.currentIndex == 1 && music.error != nil, "unreadable audio is reported and skipped")
        music.stop()
        music.replacePlaylist([invalid])
        music.startIfSelected()
        expect(!music.isPlaying && music.error != nil, "all unreadable audio stops with a visible error")
        music.replacePlaylist([first, second])
        music.volume = 0.23
        let restored = MusicPlayback(defaults: defaults)
        expect(abs(restored.volume - 0.23) < 0.001 && !restored.loopPlaylist && restored.tracks.map(\.path) == [first.path, second.path], "playlist volume and repeat preferences persist")
        music.clear()
        expect(!music.hasSelection && !music.isPlaying && music.error == nil, "remove music clears the playlist and error")
        let report: [String: Any] = ["passed": true, "checks": checks, "loopSequence": observed,
                                    "audio": "generated quarter-second mono WAV; playback muted", "timestamp": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("music-playback-test.json"))
        print("PASS: \(checks.count) music checks; loop sequence \(observed)")
    }
}
