import AppKit
import AVKit
import Darwin

/// Exercises the real player view and its display-readiness gate in a WindowServer
/// window placed entirely outside the visible desktop. This records layer state;
/// it does not claim to verify the pixels of an on-screen dissolve.
@main
enum DisplayedPlaybackTest {
    static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let first = URL(fileURLWithPath: CommandLine.arguments[1])
        let second = URL(fileURLWithPath: CommandLine.arguments[2])
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SlideshowPlayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView = view
        let playback = ContinuousPlayback()
        playback.transitionDuration = 0.35
        view.bind(to: playback)
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()

        var items: [Int] = [], repeats: [Int] = [], failures: [String] = []
        var finishes = 0, transitionSamples = 0, partiallyOpaqueSamples = 0
        var bothReadySamples = 0, missingCurrentSamples = 0
        var seenReady = [false, false]
        var observations: [[String: Any]] = []
        let started = CACurrentMediaTime()
        playback.onItem = { items.append($0); print("ITEM", $0) }
        playback.onRepeat = { repeats.append($0); print("REPEAT", $0) }
        playback.onFinished = { finishes += 1; print("FINISHED") }
        playback.onFailure = { failures.append($0.localizedDescription); print("FAILURE", $0) }
        playback.begin()
        playback.append(first, number: 0)
        let monitor = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            let readiness = playback.videoLayers.map(\.isReadyForDisplay)
            for index in 0..<2 { seenReady[index] = seenReady[index] || readiness[index] }
            if readiness.allSatisfy({ $0 }) { bothReadySamples += 1 }
            if playback.player.currentItem == nil { missingCurrentSamples += 1 }
            if playback.isTransitioning {
                transitionSamples += 1
                if playback.videoLayers.contains(where: { $0.opacity > 0 && $0.opacity < 1 }) {
                    partiallyOpaqueSamples += 1
                }
            }
            if observations.count < 300 {
                observations.append([
                    "seconds": CACurrentMediaTime() - started,
                    "currentTime": playback.player.currentTime().seconds,
                    "currentRate": playback.player.rate,
                    "readiness": readiness,
                    "opacity": playback.videoLayers.map(\.opacity),
                    "layerSize": playback.videoLayers.map { [$0.bounds.width, $0.bounds.height] },
                    "transitionFraction": playback.transitionFraction,
                    "isTransitioning": playback.isTransitioning,
                    "items": items
                ])
            }
        }
        pump(3.3)
        let repeatedBeforeSuccessor = repeats.filter { $0 == 0 }.count
        playback.append(second, number: 1)
        playback.append(first, number: 2)
        playback.finishPreparing()
        let deadline = Date().addingTimeInterval(8)
        while finishes == 0 && Date() < deadline { pump(0.03) }
        monitor.invalidate()

        var checks: [String: Bool] = [
            "real_view_enables_display_readiness_gate": playback.requiresDisplayReady,
            "successor_missing_repeats_at_least_twice": repeatedBeforeSuccessor >= 2,
            "both_real_layers_become_ready": seenReady.allSatisfy { $0 },
            "both_layers_ready_simultaneously": bothReadySamples > 3,
            "multi_frame_transition": transitionSamples >= 8,
            "multi_frame_partial_layer_opacity": partiallyOpaqueSamples >= 8,
            "all_three_items_advance_in_order": items == [0, 1, 2],
            "finish_exactly_once": finishes == 1,
            "final_item_retained_and_paused": playback.player.currentItem != nil && playback.player.rate == 0,
            "no_missing_current_item": missingCurrentSamples == 0,
            "no_player_failure": failures.isEmpty,
            "window_stays_outside_visible_screens": !NSScreen.screens.contains { $0.frame.intersects(window.frame) },
            "test_does_not_activate": !NSApp.isActive
        ]
        let waiting = exercisePreparedPhotoHistory(playback: playback, first: first, second: second)
        for (name, passed) in waiting.checks { checks[name] = passed }
        let seeded = exerciseSeededPhotoHistory(playback: playback, first: first, second: second)
        for (name, passed) in seeded.checks { checks[name] = passed }
        let variants = try exerciseRefreshedVariants(playback: playback, oldClip: first)
        for (name, passed) in variants.checks { checks[name] = passed }
        let fairness = exerciseUnseenPriority(playback: playback, clip: first)
        for (name, passed) in fairness.checks { checks[name] = passed }
        let passed = checks.values.allSatisfy { $0 }
        let report: [String: Any] = [
            "passed": passed,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "scope": "Real SlideshowPlayerView bound to two retained AVPlayerLayers in an offscreen WindowServer window. Readiness and opacity are measured, not on-screen composite pixels.",
            "checks": checks,
            "items": items,
            "repeats": repeats,
            "finishCount": finishes,
            "transitionSamples": transitionSamples,
            "partiallyOpaqueSamples": partiallyOpaqueSamples,
            "bothReadySamples": bothReadySamples,
            "missingCurrentSamples": missingCurrentSamples,
            "failures": failures,
            "preparedPhotoHistory": waiting.report,
            "seededPhotoHistory": seeded.report,
            "refreshedCacheVariants": variants.report,
            "unseenPriority": fairness.report,
            "observations": observations
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        for check in checks.keys.sorted() { print(checks[check]! ? "PASS" : "FAIL", check) }
        print("COUNTS", "transitions=\(transitionSamples)", "partial=\(partiallyOpaqueSamples)", "bothReady=\(bothReadySamples)")
        playback.stop()
        window.close()
        exit(passed ? 0 : 1)
    }

    static func exerciseRefreshedVariants(playback: ContinuousPlayback, oldClip: URL) throws
        -> (checks: [String: Bool], report: [String: Any]) {
        let freshClip = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-variant-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: oldClip, to: freshClip)
        defer { playback.stop(); try? FileManager.default.removeItem(at: freshClip) }
        var replayed: [Int] = [], usedFreshVariants = true
        var installed = false
        var freshItems: [Int] = []
        playback.onReplay = { number in
            // Updating an already viewed item must refresh its future replay
            // without forcing it back into the unseen-photo queue.
            guard installed else { return }
            replayed.append(number)
            usedFreshVariants = usedFreshVariants && (playback.player.currentItem?.asset as? AVURLAsset)?.url == freshClip
        }
        playback.onItem = { freshItems.append($0) }
        playback.onRepeat = { _ in }
        playback.begin()
        playback.addPreparedReplays([(oldClip, 300), (oldClip, 301)])
        playback.append(freshClip, number: 300)
        playback.append(freshClip, number: 301)
        installed = true
        let deadline = Date().addingTimeInterval(8)
        while Set(replayed).count < 2 && Date() < deadline { pump(0.02) }
        return ([
            "refreshed_cache_variants_replay_both_photos": Set(replayed) == Set([300, 301]),
            "refreshed_seen_photo_is_not_queued_as_new": freshItems == [301],
            "refreshed_cache_variants_replace_older_waiting_renders": usedFreshVariants && !replayed.isEmpty
        ], ["replayedPhotos": replayed, "usedFreshVariants": usedFreshVariants])
    }

    static func exerciseUnseenPriority(playback: ContinuousPlayback, clip: URL)
        -> (checks: [String: Bool], report: [String: Any]) {
        var shown: [Int] = [], repeats: [Int] = [], failures: [String] = []
        var finishes = 0
        playback.onItem = { shown.append($0) }
        playback.onReplay = { shown.append($0) }
        playback.onRepeat = { repeats.append($0) }
        playback.onFinished = { finishes += 1 }
        playback.onFailure = { failures.append($0.localizedDescription) }
        playback.onNavigation = nil
        playback.transitionDuration = 0.15
        func wait(_ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() && Date() < deadline { pump(0.02) }
            return predicate()
        }

        // Reproduce startup from cache followed by the producer returning
        // those same identities. The old code showed photo 0 twice in a row.
        playback.begin()
        playback.addPreparedReplays((0..<5).map { (clip, $0) })
        for number in 0..<5 { playback.append(clip, number: number) }
        playback.finishPreparing()
        let finished = wait { finishes == 1 }
        let startup = shown
        var checks: [String: Bool] = [
            "unseen_cached_startup_and_producer_show_each_photo_once": startup == Array(0..<5),
            "unseen_cached_startup_finishes_without_repeats": finished && repeats.isEmpty
        ]

        // Ending production must still drain cached photos that have never
        // appeared, even when they are not in the producer's pending queue.
        shown = []; finishes = 0; repeats = []
        playback.begin()
        playback.addPreparedReplays((10..<14).map { (clip, $0) })
        playback.finishPreparing()
        let cachedFinished = wait { finishes == 1 }
        let cachedOnly = shown
        checks["unseen_cached_items_drain_before_finish"] = cachedFinished && shown.count == 4 && Set(shown) == Set(10..<14)

        // Paused Next exercises the same selection policy with real ready
        // layers, without waiting a full slideshow interval for every sample.
        shown = []; finishes = 0; repeats = []
        playback.begin()
        playback.addPreparedReplays((20..<26).map { (clip, $0) })
        playback.togglePlayback()
        func next() -> Bool {
            let count = shown.count
            playback.nextPhoto()
            return wait { shown.count > count && !playback.isTransitioning }
        }
        var advanced = true
        for _ in 0..<5 { advanced = next() && advanced }
        let firstPass = shown
        for _ in 0..<12 {
            // The producer catches up with a previously seen cached photo.
            // Repeated registration must not reset the shuffle cycle.
            if let current = playback.displayedNumber { playback.append(clip, number: current) }
            playback.addPreparedReplays((20..<26).map { (clip, $0) })
            advanced = next() && advanced
        }
        let rounds = Array(shown.dropFirst(6))
        checks["unseen_first_cache_pass_has_no_duplicates"] = firstPass.count == 6 && Set(firstPass) == Set(20..<26)
        checks["repeat_cycles_survive_producer_and_cache_updates"] = rounds.count == 12 &&
            Set(rounds.prefix(6)) == Set(20..<26) && Set(rounds.suffix(6)) == Set(20..<26)
        checks["repeat_cycles_avoid_adjacent_duplicates"] = zip(shown, shown.dropFirst()).allSatisfy { $0.0 != $0.1 }

        // An unseen fresh item interrupts a speculative repeat. Displacing
        // another unseen cached candidate must not consume or lose its turn.
        playback.addPreparedReplays([(clip, 26), (clip, 27)])
        playback.append(clip, number: 28)
        let beforeNew = shown.count
        for _ in 0..<3 { advanced = next() && advanced }
        let arrivals = Array(shown.dropFirst(beforeNew))
        checks["new_arrivals_preempt_repeats_without_losing_cached_turns"] = arrivals.first == 28 && Set(arrivals) == Set([26,27,28])
        checks["selection_preserves_pause_and_frame"] = advanced && !playback.isPlaying && playback.player.currentItem != nil
        checks["selection_has_no_player_failures"] = failures.isEmpty
        playback.stop()
        return (checks, ["cachedThenProducer": startup, "cachedOnly": cachedOnly,
                         "firstPass": firstPass, "repeatRounds": rounds, "newArrivals": arrivals,
                         "failures": failures])
    }

    static func exercisePreparedPhotoHistory(playback: ContinuousPlayback, first: URL, second: URL)
        -> (checks: [String: Bool], report: [String: Any]) {
        var freshItems: [Int] = [], replayItems: [Int] = [], shown: [Int] = []
        var eventKinds: [String] = [], repeats: [Int] = [], failures: [String] = []
        var finishes = 0, fallbackOpacitySamples = 0, missingCurrentSamples = 0
        playback.onItem = {
            freshItems.append($0); shown.append($0); eventKinds.append("fresh")
            print("HISTORY FRESH", $0)
        }
        playback.onReplay = {
            replayItems.append($0); shown.append($0); eventKinds.append("replay")
            print("HISTORY REPLAY", $0)
        }
        playback.onRepeat = { repeats.append($0); print("HISTORY REPEAT", $0) }
        playback.onPlayingChanged = { print("HISTORY TRANSPORT", $0, playback.player.rate, playback.player.currentTime().seconds) }
        playback.onPlaybackWait = { print("HISTORY READINESS", $0 ?? "ready") }
        playback.onFinished = { finishes += 1; print("HISTORY FINISHED") }
        playback.onFailure = { failures.append($0.localizedDescription); print("HISTORY FAILURE", $0) }
        playback.begin()
        playback.append(first, number: 0)
        playback.append(second, number: 1)
        playback.append(first, number: 2)
        let monitor = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if playback.player.currentItem == nil { missingCurrentSamples += 1 }
            if freshItems == [0, 1, 2], playback.isTransitioning,
               playback.videoLayers.contains(where: { $0.opacity > 0 && $0.opacity < 1 }) {
                fallbackOpacitySamples += 1
            }
        }
        var deadline = Date().addingTimeInterval(14)
        while (replayItems.count < 6 || Set(replayItems).count < 3 || playback.isTransitioning) && Date() < deadline { pump(0.02) }
        let shownWhileWaiting = shown
        let replayWhileWaiting = replayItems
        let freshWhileWaiting = freshItems
        let itemsBeforeFresh = shown.count
        let fallbackOpacitySamplesWhileWaiting = fallbackOpacitySamples
        playback.append(second, number: 3)
        playback.finishPreparing()
        deadline = Date().addingTimeInterval(6)
        while finishes == 0 && Date() < deadline { pump(0.02) }
        // An erroneously retained fallback can restart after the finish callback.
        pump(1.2)
        monitor.invalidate()
        let firstEventAfterFresh = shown.count > itemsBeforeFresh ? shown[itemsBeforeFresh] : -1
        let firstKindAfterFresh = eventKinds.count > itemsBeforeFresh ? eventKinds[itemsBeforeFresh] : "missing"
        var checks: [String: Bool] = [
            "history_initial_fresh_items_stay_in_order": freshWhileWaiting == [0, 1, 2],
            "history_wait_replays_multiple_prepared_photos": replayWhileWaiting.count >= 6 && Set(replayWhileWaiting).count == 3,
            "history_first_two_repeat_rounds_cover_every_photo": replayWhileWaiting.count >= 6 && Set(replayWhileWaiting.prefix(3)) == Set(0...2) && Set(replayWhileWaiting.dropFirst(3).prefix(3)) == Set(0...2),
            "history_replays_only_current_album_prepared_items": replayWhileWaiting.allSatisfy { (0...2).contains($0) },
            "history_avoids_immediate_same_photo": zip(shownWhileWaiting, shownWhileWaiting.dropFirst()).allSatisfy { $0.0 != $0.1 },
            "history_replay_uses_multi_frame_fades": fallbackOpacitySamplesWhileWaiting >= 12,
            "history_new_photo_takes_next_slot": firstEventAfterFresh == 3 && firstKindAfterFresh == "fresh",
            "history_new_photo_played_once": freshItems == [0, 1, 2, 3],
            "history_finishes_without_endless_cache_loop": finishes == 1 && playback.player.rate == 0,
            "history_final_frame_retained": playback.player.currentItem != nil,
            "history_no_empty_current_item": missingCurrentSamples == 0,
            "history_no_player_failure": failures.isEmpty
        ]
        let historyReport: [String: Any] = [
            "freshItems": freshItems,
            "replayedItemsWhileWaiting": replayWhileWaiting,
            "shownWhileWaiting": shownWhileWaiting,
            "allShown": shown,
            "eventKinds": eventKinds,
            "samePhotoRepeats": repeats,
            "fallbackIntermediateOpacitySamples": fallbackOpacitySamplesWhileWaiting,
            "firstEventAfterNewPhoto": firstEventAfterFresh,
            "firstKindAfterNewPhoto": firstKindAfterFresh,
            "finishCount": finishes,
            "missingCurrentSamples": missingCurrentSamples,
            "failures": failures
        ]

        playback.stop()
        freshItems = []; replayItems = []; shown = []; eventKinds = []; repeats = []; finishes = 0
        playback.begin()
        playback.append(second, number: 100)
        pump(2.5)
        let restartedShown = shown
        let restartedReplays = replayItems
        let restartedRepeats = repeats
        playback.append(first, number: 101)
        playback.finishPreparing()
        deadline = Date().addingTimeInterval(4)
        while finishes == 0 && Date() < deadline { pump(0.02) }
        checks["history_stop_new_album_clears_old_photos"] = restartedShown == [100] && restartedReplays.isEmpty && restartedRepeats.allSatisfy { $0 == 100 }
        checks["history_one_prepared_photo_repeats_while_waiting"] = restartedRepeats.count >= 2
        checks["history_new_album_advances_and_finishes"] = freshItems == [100, 101] && replayItems.isEmpty && finishes == 1
        return (checks, [
            "waiting": historyReport,
            "restart": ["shownWhileWaiting": restartedShown, "replays": restartedReplays,
                        "samePhotoRepeats": restartedRepeats, "freshItems": freshItems, "finishCount": finishes]
        ])
    }

    static func exerciseSeededPhotoHistory(playback: ContinuousPlayback, first: URL, second: URL)
        -> (checks: [String: Bool], report: [String: Any]) {
        var freshItems: [Int] = [], replayItems: [Int] = [], shown: [Int] = []
        var finishes = 0, opacitySamples = 0, missingCurrentSamples = 0
        var failures: [String] = []
        playback.onItem = { freshItems.append($0); shown.append($0); print("SEEDED FRESH", $0) }
        playback.onReplay = { replayItems.append($0); shown.append($0); print("SEEDED REPLAY", $0) }
        playback.onFinished = { finishes += 1; print("SEEDED FINISHED") }
        playback.onFailure = { failures.append($0.localizedDescription); print("SEEDED FAILURE", $0) }
        playback.onRepeat = { print("SEEDED REPEAT", $0) }
        playback.begin()
        playback.addPreparedReplays([(second, 201), (first, 202)])
        pump(0.15)
        let seededAutoplaysCache = freshItems.isEmpty && replayItems == [201] && playback.player.currentItem != nil
        playback.append(first, number: 200)
        let monitor = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if playback.player.currentItem == nil { missingCurrentSamples += 1 }
            if playback.isTransitioning,
               playback.videoLayers.contains(where: { $0.opacity > 0 && $0.opacity < 1 }) {
                opacitySamples += 1
            }
        }
        var deadline = Date().addingTimeInterval(8)
        while (!replayItems.contains(201) || !replayItems.contains(202) || replayItems.count < 3 || playback.isTransitioning)
                && Date() < deadline { pump(0.02) }
        let replaysWhileWaiting = replayItems
        let opacitySamplesWhileWaiting = opacitySamples
        playback.finishPreparing()
        deadline = Date().addingTimeInterval(4)
        while finishes == 0 && Date() < deadline { pump(0.02) }
        pump(1.2)
        monitor.invalidate()
        return ([
            "seeded_pool_starts_cache_before_first_download": seededAutoplaysCache,
            "seeded_pool_plays_unvisited_cached_photos": replaysWhileWaiting.contains(201) && replaysWhileWaiting.contains(202),
            "seeded_pool_keeps_fresh_callback_accurate": freshItems == [200],
            "seeded_pool_fades_across_multiple_frames": opacitySamplesWhileWaiting >= 12,
            "seeded_pool_avoids_immediate_same_photo": zip(shown, shown.dropFirst()).allSatisfy { $0.0 != $0.1 },
            "seeded_pool_finishes_once_without_loop": finishes == 1 && playback.player.rate == 0,
            "seeded_pool_retains_final_frame": playback.player.currentItem != nil,
            "seeded_pool_has_no_empty_current_item": missingCurrentSamples == 0,
            "seeded_pool_has_no_player_failure": failures.isEmpty
        ], [
            "freshItems": freshItems,
            "replayItems": replayItems,
            "shown": shown,
            "seededAutoplaysCache": seededAutoplaysCache,
            "intermediateOpacitySamplesWhileWaiting": opacitySamplesWhileWaiting,
            "missingCurrentSamples": missingCurrentSamples,
            "finishCount": finishes,
            "failures": failures
        ])
    }
}
