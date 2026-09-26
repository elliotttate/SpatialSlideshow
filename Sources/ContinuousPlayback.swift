import AVKit

/// Two retained players let a prepared photo dissolve over the current photo.
/// All methods and callbacks run on the main thread.
final class ContinuousPlayback {
    private struct Clip { let url: URL; let number: Int }
    private let players = [AVQueuePlayer(), AVQueuePlayer()]
    let videoLayers: [AVPlayerLayer]
    private var current = 0
    var player: AVQueuePlayer { players[current] }
    var transitionDuration: Double = 0.8
    var audioEnabled = true { didSet { updateAudioVolumes() } }
    var onItem: ((Int) -> Void)?
    var onRepeat: ((Int) -> Void)?
    var onReplay: ((Int) -> Void)?
    var onTransition: ((Int, Int, Bool) -> Void)?
    var onNavigation: ((Int) -> Void)?
    var moviePhotoStarts: [Double] = [0]
    var onFinished: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var onPlayerChanged: ((AVQueuePlayer) -> Void)?
    var requiresDisplayReady = false
    private var pending: [Clip] = []
    private var currentClip: Clip?
    private var staged: Clip?
    private var stagedIsReplay = false
    private var history: [Clip] = []
    private var replayBag: [Clip] = []
    private var visits: [Clip] = []
    private var visitIndex = -1
    private var stagedVisitIndex: Int?
    private var manualAdvance = false
    private var stagedManual = false
    private var stagedPrerollStarted = false
    private var productionFinished = false
    private var loopingMovie = false
    private var active = false
    private var wantsPlaying = false
    private var internalTransport = false
    private var epoch = 0
    private var transportEpoch = 0
    private var repeatSeeking = false
    private var transitionProgress: Double?
    private var transitionLength = 0.8
    private var lastTick = CACurrentMediaTime()
    private var timer: Timer?
    private var endObserver: NSObjectProtocol?
    private var rateObservers: [NSKeyValueObservation] = []
    var queuedCount: Int { (player.currentItem == nil ? 0 : 1) + pending.count }
    var isTransitioning: Bool { transitionProgress != nil }
    var transitionFraction: Double { transitionProgress ?? 0 }
    var displayedNumber: Int? { currentClip?.number }
    var isPlaying: Bool { wantsPlaying }

    init() {
        videoLayers = players.map { AVPlayerLayer(player: $0) }
        for index in players.indices {
            players[index].automaticallyWaitsToMinimizeStalling = false
            players[index].actionAtItemEnd = .pause
            videoLayers[index].videoGravity = .resizeAspect
            videoLayers[index].opacity = index == 0 ? 1 : 0
            rateObservers.append(players[index].observe(\.rate, options: [.new]) { [weak self] observed, change in
                guard let self else { return }
                let generation = self.epoch
                let transportGeneration = self.transportEpoch
                let observedItem = observed.currentItem
                let rate = change.newValue ?? observed.rate
                let duration = observed.currentItem?.duration.seconds ?? .nan
                let atBoundary = rate == 0 && duration.isFinite && observed.currentTime().seconds >= duration - 0.08
                let internalChange = !self.active || self.internalTransport || self.repeatSeeking || atBoundary
                DispatchQueue.main.async { [weak self] in
                    guard let self, !internalChange, self.epoch == generation,
                          self.transportEpoch == transportGeneration,
                          observed.currentItem === observedItem, observed.rate == rate else { return }
                    self.rateChanged(observed, rate: rate)
                }
            })
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem,
                  self.active, item === self.player.currentItem else { return }
            self.reachedEnd()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }
    deinit {
        timer?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
    func begin(loopMovie: Bool = false) {
        stop(); active = true; loopingMovie = loopMovie; productionFinished = false
    }
    func addPreparedReplays(_ clips: [(URL, Int)]) {
        guard active, !loopingMovie else { return }
        for (url, number) in clips where !history.contains(where: { $0.number == number }) {
            history.append(Clip(url: url, number: number))
        }
        replayBag.removeAll()
        if currentClip != nil { preload() }
    }
    func append(_ url: URL, number: Int) {
        guard active else { return }
        if player.currentItem == nil {
            let clip = Clip(url: url, number: number)
            currentClip = clip
            visits = [clip]; visitIndex = 0
            rememberPrepared(clip)
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            wantsPlaying = true; player.play(); onItem?(number); onPlayingChanged?(true)
            preload()
        } else { pending.append(Clip(url: url, number: number)); preload() }
    }
    func finishPreparing() {
        productionFinished = true
        if stagedIsReplay && !isTransitioning && !manualAdvance { clearStaged(); preload() }
        if player.currentItem == nil && active { active = false; onFinished?() }
    }
    func stop() {
        epoch += 1; active = false; wantsPlaying = false; repeatSeeking = false
        transitionProgress = nil; pending.removeAll(); staged = nil; stagedIsReplay = false; currentClip = nil
        history.removeAll(); replayBag.removeAll()
        visits.removeAll(); visitIndex = -1; stagedVisitIndex = nil; manualAdvance = false; stagedManual = false
        stagedPrerollStarted = false
        for p in players { p.pause(); p.removeAllItems() }
        setOpacity(current: 1, incoming: 0)
        onPlayingChanged?(false)
    }
    func togglePlayback() {
        guard player.currentItem != nil else { return }
        transportEpoch += 1
        wantsPlaying.toggle()
        setTransport(playing: wantsPlaying)
        onPlayingChanged?(wantsPlaying)
    }
    func previousPhoto() { navigate(forward: false) }
    func nextPhoto() { navigate(forward: true) }
    private func navigate(forward: Bool) {
        guard player.currentItem != nil else { return }
        if loopingMovie {
            let time = player.currentTime().seconds
            let index = moviePhotoStarts.lastIndex(where: { $0 <= time + 0.05 }) ?? 0
            let target = min(moviePhotoStarts.count - 1, max(0, index + (forward ? 1 : -1)))
            guard moviePhotoStarts.indices.contains(target) else { return }
            player.seek(to: CMTime(seconds: moviePhotoStarts[target], preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            onNavigation?(target)
            return
        }
        // Finish an already visible dissolve before choosing another photo.
        if isTransitioning { completeTransition() }
        guard !manualAdvance else { return }
        active = true
        if !forward {
            guard visitIndex > 0 else {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                return
            }
            clearStaged()
            stageVisit(at: visitIndex - 1)
        } else { preload() }
        guard staged != nil else { return }
        // Keep the current frame until the destination layer has a real frame,
        // including when navigating while paused or waiting for a download.
        epoch += 1; repeatSeeking = false
        player.currentItem?.cancelPendingSeeks()
        manualAdvance = true; stagedManual = true
    }
    private func stageVisit(at index: Int) {
        staged = visits[index]; stagedVisitIndex = index; stagedIsReplay = false
        incoming.replaceCurrentItem(with: AVPlayerItem(url: visits[index].url))
        stagedPrerollStarted = false
    }
    private var incoming: AVQueuePlayer { players[1 - current] }
    private func rememberPrepared(_ clip: Clip) {
        // Once today's render plays, future waiting replays should use it in
        // preference to a variant recovered from an earlier session.
        if let index = history.firstIndex(where: { $0.number == clip.number }) { history[index] = clip }
        else { history.append(clip) }
    }
    private func setTransport(playing: Bool) {
        internalTransport = true
        if playing { player.play(); if isTransitioning { incoming.play() } }
        else { player.pause(); incoming.pause() }
        internalTransport = false
    }
    private func rateChanged(_ observed: AVQueuePlayer, rate: Float) {
        guard active, observed === player, !internalTransport, !repeatSeeking else { return }
        let time = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .nan
        // AVFoundation pauses itself at the natural boundary. That is not a user pause.
        if rate == 0, duration.isFinite, time >= duration - 0.08 { return }
        let playing = rate != 0
        guard wantsPlaying != playing else { return }
        wantsPlaying = playing
        if isTransitioning { if playing { incoming.play() } else { incoming.pause() } }
        onPlayingChanged?(playing)
    }
    private func preload() {
        guard active, !loopingMovie, !isTransitioning else { return }
        // New photos take priority over a cached replay that has not started.
        if stagedIsReplay && !pending.isEmpty && !manualAdvance { clearStaged() }
        guard staged == nil else { return }
        if visitIndex + 1 < visits.count {
            stageVisit(at: visitIndex + 1)
            return
        }
        let clip: Clip
        if let next = pending.first {
            clip = next; stagedIsReplay = false
        } else {
            guard !productionFinished else { return }
            if replayBag.isEmpty {
                replayBag = history.filter { $0.number != currentClip?.number }.shuffled()
            }
            guard let replay = replayBag.popLast() else { return }
            clip = replay; stagedIsReplay = true
        }
        staged = clip
        incoming.replaceCurrentItem(with: AVPlayerItem(url: clip.url))
        stagedPrerollStarted = false
    }
    private func clearStaged() {
        incoming.cancelPendingPrerolls()
        incoming.pause(); incoming.replaceCurrentItem(with: nil)
        staged = nil; stagedIsReplay = false; stagedVisitIndex = nil; manualAdvance = false; stagedManual = false
        stagedPrerollStarted = false
    }
    private var nextReady: Bool {
        guard staged != nil, incoming.currentItem?.status == .readyToPlay else { return false }
        return !requiresDisplayReady || videoLayers[1 - current].isReadyForDisplay
    }
    private func tick() {
        let now = CACurrentMediaTime(), delta = min(now - lastTick, 0.1)
        lastTick = now
        guard active else { return }
        if let item = incoming.currentItem, item.status == .failed, let failed = staged {
            if let error = item.error { onFailure?(error) }
            if stagedIsReplay {
                history.removeAll { $0.number == failed.number }
                replayBag.removeAll { $0.number == failed.number }
            } else if stagedVisitIndex == nil && !pending.isEmpty { pending.removeFirst() }
            transitionProgress = nil; setOpacity(current: 1, incoming: 0)
            clearStaged()
            preload()
        }
        // Replacing the item is asynchronous. Preroll before ReadyToPlay raises
        // an Objective-C exception, especially when navigating larger clips.
        if staged != nil, !stagedPrerollStarted,
           incoming.status == .readyToPlay, incoming.currentItem?.status == .readyToPlay {
            stagedPrerollStarted = true
            incoming.preroll(atRate: 1) { _ in }
        }
        if manualAdvance && nextReady {
            manualAdvance = false
            if wantsPlaying && transitionDuration > 0 {
                transitionLength = min(0.25, transitionDuration)
                startTransition()
            } else { completeTransition() }
        }
        guard wantsPlaying else { return }
        if let progress = transitionProgress {
            let fraction = min(1, progress + delta / transitionLength)
            transitionProgress = fraction
            setOpacity(current: 1, incoming: Float(fraction))
            if fraction >= 1 { completeTransition() }
            return
        }
        guard !loopingMovie, !repeatSeeking, nextReady,
              let item = player.currentItem else { return }
        let remaining = item.duration.seconds - player.currentTime().seconds
        if remaining.isFinite, remaining > 0, remaining <= max(0.02, transitionDuration), transitionDuration > 0 {
            transitionLength = max(0.05, min(transitionDuration, remaining))
            startTransition()
        }
    }
    private func setOpacity(current value: Float, incoming next: Float) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayers[current].zPosition = 0; videoLayers[1 - current].zPosition = 1
        videoLayers[current].opacity = value; videoLayers[1 - current].opacity = next
        CATransaction.commit()
        updateAudioVolumes()
    }
    private func updateAudioVolumes() {
        let fraction = Float(transitionProgress ?? 0)
        player.volume = audioEnabled ? 1 - fraction : 0
        incoming.volume = audioEnabled ? fraction : 0
    }
    private func startTransition() {
        guard nextReady, !isTransitioning else { return }
        transitionProgress = 0; incoming.play(); setOpacity(current: 1, incoming: 0)
        if let from = currentClip, let to = staged { onTransition?(from.number, to.number, stagedIsReplay) }
    }
    private func completeTransition() {
        guard let clip = staged else { return }
        internalTransport = true
        defer { internalTransport = false }
        let old = player, replay = stagedIsReplay, navigation = stagedVisitIndex, manual = stagedManual
        if !replay && navigation == nil {
            pending.removeFirst()
            rememberPrepared(clip)
            replayBag.removeAll()
        }
        if let navigation { visitIndex = navigation }
        else {
            if visitIndex + 1 < visits.count { visits.removeSubrange((visitIndex + 1)..<visits.count) }
            visits.append(clip); visitIndex = visits.count - 1
        }
        current = 1 - current; currentClip = clip
        transitionProgress = nil; staged = nil; stagedIsReplay = false; stagedVisitIndex = nil; manualAdvance = false; stagedManual = false
        setOpacity(current: 1, incoming: 0)
        old.pause(); old.replaceCurrentItem(with: nil)
        onPlayerChanged?(player)
        if navigation != nil { onNavigation?(clip.number) }
        else {
            if replay { onReplay?(clip.number) } else { onItem?(clip.number) }
            if manual { onNavigation?(clip.number) }
        }
        if wantsPlaying { player.play() } else { player.pause() }
        preload()
    }
    private func reachedEnd() {
        if isTransitioning { return } // Keep the outgoing final frame during overlap.
        if !loopingMovie, nextReady {
            if transitionDuration > 0 { transitionLength = transitionDuration; startTransition() }
            else { completeTransition() }
            return
        }
        if productionFinished && pending.isEmpty && !loopingMovie {
            active = false; wantsPlaying = false; player.pause(); onPlayingChanged?(false); onFinished?(); return
        }
        guard let number = currentClip?.number else { return }
        onRepeat?(number)
        guard active else { return }
        repeatSeeking = true
        let generation = epoch
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            DispatchQueue.main.async {
                guard let self, self.active, self.epoch == generation else { return }
                self.repeatSeeking = false
                if completed, self.wantsPlaying { self.player.play() }
            }
        }
    }
}
