import AppKit
import AVKit
import Darwin

/// Real retained AVPlayerLayers in an offscreen WindowServer window. Tests
/// frame readiness and transport, not the pixels of the composited image.
@main
enum PhotoNavigationTest {
    static var checks: [String: Bool] = [:]
    static var evidence: [String: Any] = [:]
    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    @discardableResult
    static func wait(_ timeout: Double = 3, _ predicate: () -> Bool) -> Bool {
        let end = CACurrentMediaTime() + timeout
        while !predicate() && CACurrentMediaTime() < end { pump(0.01) }
        return predicate()
    }
    static func check(_ name: String, _ passed: Bool) {
        checks[name] = passed; print(passed ? "PASS" : "FAIL", name)
    }
    static func ready(_ playback: ContinuousPlayback) -> Bool {
        playback.videoLayers.contains { $0.player === playback.player && $0.isReadyForDisplay && $0.opacity == 1 }
    }
    static func move(_ playback: ContinuousPlayback, to number: Int, forward: Bool) -> Double {
        let start = CACurrentMediaTime()
        if forward { playback.nextPhoto() } else { playback.previousPhoto() }
        let arrived = wait { playback.displayedNumber == number && !playback.isTransitioning && ready(playback) }
        return arrived ? CACurrentMediaTime() - start : -1
    }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let short = URL(fileURLWithPath: CommandLine.arguments[1])
        let long = URL(fileURLWithPath: CommandLine.arguments[2])
        let report = URL(fileURLWithPath: CommandLine.arguments[3])
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SlideshowPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let playback = ContinuousPlayback()
        window.contentView = view; view.bind(to: playback); window.orderBack(nil); view.layoutSubtreeIfNeeded()
        var fresh: [Int] = [], replay: [Int] = [], shown: [Int] = [], navigation: [Int] = [], failures: [String] = []
        var playingEvents: [[String: Any]] = []
        var finishes = 0, missingFrames = 0
        playback.onItem = { fresh.append($0); shown.append($0) }
        playback.onReplay = { replay.append($0); shown.append($0) }
        playback.onNavigation = { navigation.append($0) }
        playback.onFinished = { finishes += 1 }
        playback.onFailure = { failures.append($0.localizedDescription) }
        playback.onPlayingChanged = {
            let time = playback.player.currentTime().seconds
            playingEvents.append(["playing": $0, "displayed": playback.displayedNumber ?? -1, "rate": playback.player.rate, "time": time.isFinite ? time : -1])
        }

        playback.transitionDuration = 0.8
        playback.begin(); playback.append(long, number: 0); playback.append(long, number: 1); playback.append(long, number: 2); playback.finishPreparing()
        check("real_view_display_readiness_enabled", playback.requiresDisplayReady)
        check("long_clip_displayed", wait { ready(playback) && playback.videoLayers.allSatisfy(\.isReadyForDisplay) })
        let longDuration = playback.player.currentItem?.duration.seconds ?? 0
        check("manual_skip_fixture_is_at_least_30_seconds", longDuration >= 30)
        let monitor = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if playback.player.currentItem == nil { missingFrames += 1 }
        }
        let nextSeconds = move(playback, to: 1, forward: true)
        check("next_skips_32_second_clip_in_under_one_second", nextSeconds >= 0 && nextSeconds < 1)
        check("next_is_actually_playing", playback.player.rate > 0)
        check("second_next_arrives", move(playback, to: 2, forward: true) >= 0)
        check("back_uses_visited_photo", move(playback, to: 1, forward: false) >= 0)
        check("forward_retraces_history", move(playback, to: 2, forward: true) >= 0)
        playback.togglePlayback(); pump(0.08)
        let rateAfterPause = playback.player.rate
        check("pause_command_stops_before_navigation", rateAfterPause == 0)
        let pausedBack = move(playback, to: 1, forward: false)
        let pausedTime = playback.player.currentTime().seconds
        pump(0.25)
        let rateAfterPausedBack = playback.player.rate
        let timeAfterPausedBack = playback.player.currentTime().seconds
        check("paused_back_arrives_and_retains_ready_frame", pausedBack >= 0 && ready(playback))
        check("paused_back_preserves_paused_transport", playback.player.rate == 0 && abs(playback.player.currentTime().seconds - pausedTime) < 0.04)
        check("paused_forward_retraces_without_resuming", move(playback, to: 2, forward: true) >= 0 && playback.player.rate == 0)
        check("navigation_callback_reports_actual_destinations", navigation == [1, 2, 1, 2, 1, 2])
        print("PAUSE DIAGNOSTIC", rateAfterPause, rateAfterPausedBack, pausedTime, timeAfterPausedBack, playingEvents)
        evidence["longClip"] = ["durationSeconds": longDuration, "skipSeconds": nextSeconds, "pausedBackSeconds": pausedBack, "fresh": fresh, "navigation": navigation, "rateAfterPause": rateAfterPause, "rateAfterPausedBack": rateAfterPausedBack, "timeAfterPausedBack": timeAfterPausedBack, "timeBeforePausedWait": pausedTime, "playingEvents": playingEvents]
        monitor.invalidate()
        check("manual_navigation_never_removes_current_item", missingFrames == 0)

        fresh = []; replay = []; shown = []; navigation = []; finishes = 0
        playback.begin(); playback.transitionDuration = 0.2
        playback.addPreparedReplays([(short, 101), (short, 102), (short, 103)])
        playback.append(short, number: 100)
        check("cached_random_replays_are_visited", wait(12) { replay.count >= 5 && !playback.isTransitioning })
        playback.togglePlayback(); pump(0.05)
        let visited = shown
        var actualBack: [Int] = [], actualForward: [Int] = []
        if visited.count >= 4 {
            for index in stride(from: visited.count - 2, through: visited.count - 4, by: -1) {
                _ = move(playback, to: visited[index], forward: false)
                actualBack.append(playback.displayedNumber ?? -1)
            }
            for index in (visited.count - 3)..<visited.count {
                _ = move(playback, to: visited[index], forward: true)
                actualForward.append(playback.displayedNumber ?? -1)
            }
        }
        check("back_follows_actual_cached_visit_order", visited.count >= 4 && actualBack == Array(visited.dropLast().suffix(3).reversed()))
        check("forward_retraces_actual_cached_visit_order", visited.count >= 4 && actualForward == Array(visited.suffix(3)))
        check("cached_history_navigation_remains_paused", playback.player.rate == 0 && ready(playback))
        check("cached_history_navigation_does_not_duplicate_fresh_or_replay_events", fresh == [100] && shown == visited)
        evidence["cachedHistory"] = ["visited": visited, "back": actualBack, "forward": actualForward, "navigation": navigation]

        fresh = []; replay = []; shown = []; navigation = []; finishes = 0
        playback.begin(); playback.transitionDuration = 0.5
        for number in 10...14 { playback.append(short, number: number) }
        playback.finishPreparing()
        check("natural_fade_started_before_manual_next", wait { playback.isTransitioning && playback.transitionFraction > 0.15 && playback.transitionFraction < 0.8 })
        let fadeVolumes = playback.videoLayers.compactMap { $0.player?.volume }
        check("video_audio_follows_crossfade", fadeVolumes.count == 2 && fadeVolumes.allSatisfy { $0 > 0 && $0 < 1 } && abs(fadeVolumes.reduce(0, +) - 1) < 0.001)
        playback.nextPhoto()
        check("next_during_fade_advances_to_following_photo", wait { playback.displayedNumber == 12 && !playback.isTransitioning })
        check("next_during_fade_keeps_remaining_queue", wait(8) { finishes == 1 } && fresh == [10, 11, 12, 13, 14])
        check("final_frame_retained_and_paused", playback.displayedNumber == 14 && playback.player.currentItem != nil && playback.player.rate == 0 && ready(playback))
        check("back_from_final_frame_works_while_paused", move(playback, to: 13, forward: false) >= 0 && playback.player.rate == 0 && ready(playback))
        check("forward_from_final_frame_back_retraces", move(playback, to: 14, forward: true) >= 0 && playback.player.rate == 0)
        evidence["fadeAndFinal"] = ["fresh": fresh, "navigation": navigation, "finishes": finishes]

        fresh = []; replay = []; navigation = []; shown = []; finishes = 0
        playback.begin(); playback.transitionDuration = 0.5
        for number in 30...32 { playback.append(short, number: number) }
        playback.finishPreparing()
        check("natural_fade_started_before_manual_back", wait { playback.isTransitioning && playback.transitionFraction > 0.15 && playback.transitionFraction < 0.8 })
        check("back_during_fade_returns_to_outgoing_photo", move(playback, to: 30, forward: false) >= 0)
        check("back_during_fade_preserves_queue_and_finishes", wait(6) { finishes == 1 } && fresh == [30, 31, 32] && playback.displayedNumber == 32)
        evidence["backDuringFade"] = ["fresh": fresh, "navigation": navigation, "finishes": finishes]

        playback.stop(); fresh = []; replay = []; navigation = []; shown = []
        check("stop_clears_displayed_photo", playback.displayedNumber == nil && playback.player.currentItem == nil)
        playback.begin(); playback.append(long, number: 200); playback.finishPreparing()
        _ = wait { ready(playback) }; playback.togglePlayback(); pump(0.05)
        playback.previousPhoto(); pump(0.25); playback.nextPhoto(); pump(0.25)
        check("new_session_cannot_navigate_to_old_history", playback.displayedNumber == 200 && fresh == [200] && replay.isEmpty && navigation.isEmpty && playback.player.rate == 0)

        playback.begin(); playback.append(long, number: 0)
        _ = wait { ready(playback) }; playback.togglePlayback(); pump(0.05)
        let bufferedPauseTime = playback.player.currentTime().seconds
        for number in 1...500 { playback.append(long, number: number) }
        playback.finishPreparing(); pump(0.3)
        check("paused_album_accepts_all_501_prepared_urls", playback.queuedCount == 501)
        check("large_paused_buffer_uses_only_two_player_items", playback.videoLayers.compactMap { ($0.player as? AVQueuePlayer)?.items().count }.reduce(0, +) <= 2)
        check("finishing_preparation_preserves_paused_photo_and_time", !playback.isPlaying && playback.displayedNumber == 0 && abs(playback.player.currentTime().seconds - bufferedPauseTime) < 0.04 && ready(playback))
        playback.audioEnabled = false
        check("video_sound_option_mutes_both_players", playback.videoLayers.allSatisfy { $0.player?.volume == 0 })
        playback.audioEnabled = true
        check("video_sound_option_restores_only_visible_player", playback.player.volume == 1 && playback.videoLayers.filter { $0.player !== playback.player }.allSatisfy { $0.player?.volume == 0 })
        check("large_paused_buffer_next_preserves_pause", move(playback, to: 1, forward: true) >= 0 && !playback.isPlaying)
        playback.stop()
        check("stop_clears_large_prepared_queue", playback.queuedCount == 0)

        playback.begin(loopMovie: true); playback.moviePhotoStarts = [0, 6, 12, 18]
        playback.append(long, number: 0); playback.finishPreparing()
        _ = wait { ready(playback) }; playback.togglePlayback(); pump(0.05)
        playback.nextPhoto()
        check("loop_movie_next_seeks_to_chapter", wait { abs(playback.player.currentTime().seconds - 6) < 0.08 })
        playback.nextPhoto()
        check("loop_movie_second_next_seeks_to_chapter", wait { abs(playback.player.currentTime().seconds - 12) < 0.08 })
        playback.previousPhoto()
        check("loop_movie_previous_seeks_to_prior_chapter", wait { abs(playback.player.currentTime().seconds - 6) < 0.08 })
        check("loop_movie_chapter_navigation_preserves_pause_and_frame", playback.player.rate == 0 && ready(playback))
        check("no_player_failures", failures.isEmpty)
        check("window_stays_offscreen_and_inactive", !NSApp.isActive && !NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        evidence["passed"] = checks.values.allSatisfy { $0 }
        evidence["checks"] = checks; evidence["failures"] = failures
        evidence["timestamp"] = ISO8601DateFormatter().string(from: Date())
        evidence["scope"] = "Real SlideshowPlayerView with requiresDisplayReady in an offscreen WindowServer window; checks retained item, layer readiness, timing and callbacks, not composite pixels."
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        playback.stop(); window.close()
        exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}
