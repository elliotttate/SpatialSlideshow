import SwiftUI
import AVKit
import Photos
import UniformTypeIdentifiers

final class SlideshowModel: ObservableObject {
    @Published var photos: [URL] = []
    @Published var seconds = UserDefaults.standard.object(forKey: "seconds") as? Double ?? 9.0 { didSet { UserDefaults.standard.set(seconds, forKey: "seconds") } }
    @Published var motion = UserDefaults.standard.object(forKey: "motion") as? Double ?? 1.8 { didSet { UserDefaults.standard.set(motion, forKey: "motion") } }
    @Published var framing = FramingMode(rawValue: UserDefaults.standard.string(forKey: "framing") ?? "fit") ?? .fit { didSet { UserDefaults.standard.set(framing.rawValue, forKey: "framing") } }
    @Published var motionStyle = MotionStyle(rawValue: UserDefaults.standard.object(forKey: "motionStyle") as? Int ?? -1) ?? .varied { didSet { UserDefaults.standard.set(motionStyle.rawValue, forKey: "motionStyle") } }
    @Published var photoVersion = PhotoVersion(rawValue: UserDefaults.standard.string(forKey: "photoVersion") ?? "original") ?? .original { didSet { UserDefaults.standard.set(photoVersion.rawValue, forKey: "photoVersion") } }
    @Published var expandPhotoEdges = UserDefaults.standard.bool(forKey: "expandPhotoEdges") { didSet { UserDefaults.standard.set(expandPhotoEdges, forKey: "expandPhotoEdges") } }
    @Published var expansionPercent = min(20, max(1, UserDefaults.standard.object(forKey: "expansionPercent") as? Int ?? 5)) { didSet { UserDefaults.standard.set(expansionPercent, forKey: "expansionPercent") } }
    @Published var expansionZoomOutPercent = min(40, max(0, UserDefaults.standard.object(forKey: "expansionZoomOutPercent") as? Int ?? 0)) { didSet { UserDefaults.standard.set(expansionZoomOutPercent, forKey: "expansionZoomOutPercent") } }
    var effectiveExpansionZoomOutPercent: Int { min(expansionPercent * 2, expansionZoomOutPercent) }
    @Published var outputLongEdge = UserDefaults.standard.object(forKey: "outputLongEdge") as? Int ?? 3840 { didSet { UserDefaults.standard.set(outputLongEdge, forKey: "outputLongEdge") } }
    @Published var crossfade = UserDefaults.standard.object(forKey: "crossfade") as? Bool ?? true { didSet { UserDefaults.standard.set(crossfade, forKey: "crossfade"); playback.transitionDuration = crossfade ? 0.8 : 0 } }
    @Published var shuffleAlbum = UserDefaults.standard.object(forKey: "shuffleAlbum") as? Bool ?? true { didSet { UserDefaults.standard.set(shuffleAlbum, forKey: "shuffleAlbum") } }
    @Published var includeVideos = UserDefaults.standard.bool(forKey: "includeVideos") { didSet { UserDefaults.standard.set(includeVideos, forKey: "includeVideos") } }
    @Published var videoSound = UserDefaults.standard.object(forKey: "videoSound") as? Bool ?? true { didSet { UserDefaults.standard.set(videoSound, forKey: "videoSound"); playback.audioEnabled = videoSound } }
    @Published var busy = false
    @Published var albumPlaying = false
    @Published var fullScreen = false
    @Published var status = "Choose photos or browse an album"
    @Published var preparationStatus: String?
    @Published var preparationIssue: String?
    @Published var error: String?
    @Published var movie: URL?
    @Published var albumTitle: String?
    @Published var albumCount = 0
    @Published var albumVideoCount = 0
    @Published var cachedPhotoCount = 0
    @Published var preparedPhotoCount = 0
    let playback = ContinuousPlayback()
    private let displaySleep = DisplaySleepInhibitor()
    var player: AVQueuePlayer { playback.player }
    let music = MusicPlayback()
    let library = AlbumLibrary()
    private var session: RenderSession?
    private var lastAlbum: [PHAsset] = []
    private var lastAlbumDefinition: PhotoAlbum?
    // Rendering takes a snapshot. Preferences can change while the current
    // queue keeps running; restarting is explicit so playback never resets
    // merely because someone drags a settings slider.
    private struct RenderSettings: Equatable {
        let seconds: Double
        let motion: Double
        let style: MotionStyle
        let photoVersion: PhotoVersion
        let expansion: Int
        let zoomOut: Int
        let outputLongEdge: Int
        let shuffleAlbum: Bool
        let includeVideos: Bool
        let movieFraming: FramingMode?
        let movieFades: Bool?
    }
    @Published private var renderedSettings: RenderSettings?
    private var currentRenderSettings: RenderSettings {
        let isAlbum = albumTitle != nil
        return RenderSettings(seconds: seconds, motion: motion, style: motionStyle,
                              photoVersion: photoVersion, expansion: expandPhotoEdges ? expansionPercent : 0,
                              zoomOut: expandPhotoEdges ? effectiveExpansionZoomOutPercent : 0,
                              outputLongEdge: outputLongEdge, shuffleAlbum: isAlbum && shuffleAlbum,
                              includeVideos: isAlbum && includeVideos,
                              movieFraming: isAlbum ? nil : framing, movieFades: isAlbum ? nil : crossfade)
    }
    var hasPendingRenderSettings: Bool {
        guard let renderedSettings, albumTitle != nil || !photos.isEmpty else { return false }
        return renderedSettings != currentRenderSettings
    }
    func applyRenderSettings() {
        if albumTitle != nil { replayAlbum() }
        else if !photos.isEmpty { stop(); build() }
    }
    private var albumVideoIndexes: Set<Int> = []
    private var skipped = 0
    private var pendingFullscreen = false
    private var playbackLog: URL?
    private var preparingPhoto: Int?
    private var renderingPhase: String?
    private var loadingPhases: [Int: String] = [:]
    private var storageBlockages: [Int: String] = [:]
    private(set) weak var window: NSWindow?

    func attachWindow(_ window: NSWindow) { self.window = window }

    init() {
        playback.transitionDuration = crossfade ? 0.8 : 0
        playback.audioEnabled = videoSound
        playback.onPlayingChanged = { [weak self] playing in
            self?.displaySleep.setPlaybackActive(playing)
            if playing { self?.music.startIfSelected() } else { self?.music.pause() }
        }
        playback.onNavigation = { [weak self] number in
            guard let self else { return }
            self.status = "\(self.albumTitle ?? "Slideshow") · \(self.itemLabel(number)) \(number + 1)" + (self.albumTitle != nil ? " of \(self.albumCount)" : "")
            self.logPlayback("Navigated to \(self.itemLabel(number).lowercased()) \(number + 1)")
        }
        playback.onItem = { [weak self] number in
            guard let self, self.albumPlaying else { return }
            self.status = "\(self.albumTitle ?? "Album") · \(self.itemLabel(number)) \(number + 1) of \(self.albumCount)" + (self.skipped > 0 ? " · \(self.skipped) unavailable" : "")
            self.logPlayback("Playing new \(self.itemLabel(number).lowercased()) \(number + 1)")
        }
        playback.onRepeat = { [weak self] number in
            guard let self, self.albumPlaying else { return }
            self.status = "Repeating \(self.itemLabel(number).lowercased()) \(number + 1) while the next item prepares…"
            self.logPlayback("Waiting; repeating photo \(number + 1)")
        }
        playback.onReplay = { [weak self] number in
            guard let self, self.albumPlaying else { return }
            self.status = "Waiting for the next item · Shuffling prepared items"
            self.logPlayback("Replaying prepared photo \(number + 1)")
        }
        playback.onTransition = { [weak self] from, to, replay in
            self?.logPlayback("Fade \(from + 1) → \(to + 1) · \(replay ? "cached replay" : "new photo")")
        }
        playback.onFinished = { [weak self] in
            guard let self, self.albumPlaying else { return }
            self.albumPlaying = false; self.busy = false; self.session = nil
            self.preparationStatus = nil; self.preparingPhoto = nil
            self.music.stop()
            self.logPlayback("Album finished")
            self.status = "Finished \(self.albumTitle ?? "album") · \(self.albumCount - self.skipped) items" + (self.skipped > 0 ? " · \(self.skipped) unavailable" : "")
        }
        playback.onFailure = { [weak self] _ in self?.skipped += 1 }
        if let demo = Bundle.main.url(forResource: "Demo", withExtension: "mp4") {
            let demoStarts: [Double] = [0, 6, 11.2, 16.4, 21.6, 26.8]
            playMovie(demo, photoStarts: demoStarts)
        }
    }
    private func itemLabel(_ index: Int) -> String { albumVideoIndexes.contains(index) ? "Video" : "Photo" }
    private func refreshPreparationStatus() {
        preparationIssue = storageBlockages.keys.min().flatMap { storageBlockages[$0] }
        if let index = preparingPhoto, let renderingPhase {
            preparationStatus = "\(itemLabel(index)) \(index + 1) · \(renderingPhase)"
        } else if let index = loadingPhases.keys.min(), let phase = loadingPhases[index] {
            preparationStatus = "\(itemLabel(index)) \(index + 1) · \(phase)"
        } else {
            preparationStatus = nil
        }
        if !loadingPhases.isEmpty {
            preparationStatus = (preparationStatus ?? "") + "\nLoading ahead · \(loadingPhases.count) items"
        }
    }
    var albumCountDescription: String {
        albumVideoCount > 0 ? "\(albumCount - albumVideoCount) photos · \(albumVideoCount) videos" : "\(albumCount) photos"
    }
    private func logPlayback(_ message: String) {
        guard let playbackLog else { return }
        let data = Data("\(Date()) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: playbackLog) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
        }
    }
    static func support() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("Photos Spatial Slideshow", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    var dimensions: String {
        let frame = window?.screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let scale = Double(outputLongEdge) / max(frame.width, frame.height)
        let w = max(256, Int(frame.width * scale) / 2 * 2), h = max(256, Int(frame.height * scale) / 2 * 2)
        return "\(w)x\(h)"
    }
    func enterFullscreen() {
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        player.play()
    }
    func exitFullscreen() {
        if let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
    func stop() {
        session?.cancel(); session = nil
        busy = false; albumPlaying = false; pendingFullscreen = false
        preparationStatus = nil; preparingPhoto = nil
        renderingPhase = nil; loadingPhases.removeAll()
        storageBlockages.removeAll(); preparationIssue = nil
        playback.stop()
        music.stop()
        status = "Stopped"
    }
    func playMovie(_ url: URL, photoStarts: [Double] = [0]) {
        movie = url
        playback.moviePhotoStarts = photoStarts
        playback.begin(loopMovie: true)
        playback.append(url, number: 0)
    }
    func choose() {
        let panel = NSOpenPanel(); panel.title = "Choose photos for the spatial slideshow"
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            photos = panel.urls; albumTitle = nil; lastAlbum = []; lastAlbumDefinition = nil; albumVideoCount = 0; albumVideoIndexes = []
            renderedSettings = nil
            status = "\(photos.count) photos selected"
        }
    }
    func playAlbum(_ title: String, assets selection: [PHAsset]) {
        let assets = selection.filter { $0.mediaType == .image || (includeVideos && $0.mediaType == .video) }
        guard !assets.isEmpty, let tools = Bundle.main.resourceURL else { return }
        stop(); movie = nil; photos = []; albumTitle = title; lastAlbum = selection; albumCount = assets.count
        renderedSettings = currentRenderSettings
        albumVideoCount = assets.filter { $0.mediaType == .video }.count
        if let selected = library.selected, selected.title == title { lastAlbumDefinition = selected }
        busy = true; albumPlaying = true; skipped = 0; pendingFullscreen = true; cachedPhotoCount = 0; preparedPhotoCount = 0
        playbackLog = try? Self.support().appendingPathComponent("Playback.log")
        if let playbackLog { try? Data().write(to: playbackLog) }
        logPlayback("Starting \(title) · \(albumCountDescription) · fades \(crossfade ? "on" : "off")")
        playback.begin()
        let task = RenderSession(); session = task
        let duration = seconds, strength = motion, style = motionStyle, version = photoVersion, edge = outputLongEdge
        let expandEdges = expandPhotoEdges, extraPercent = expansionPercent, zoomOut = effectiveExpansionZoomOutPercent
        // Shuffle a playback copy once per run. Keep the original album order
        // for replay, and visit each photo exactly once before finishing.
        let orderedAssets = shuffleAlbum ? assets.shuffled() : assets
        albumVideoIndexes = Set(orderedAssets.indices.filter { orderedAssets[$0].mediaType == .video })
        status = "Preparing the first item of \(assets.count)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let root = try Self.support()
                let expansion = try PhotoExpansionConfiguration.resolve(enabled: expandEdges, percent: extraPercent, zoomOutPercent: zoomOut, tools: tools)
                // Previously rendered photos from this album can fill a wait,
                // even before their turn in this run. No new model work here.
                let cacheLookupStarted = Date()
                let sources = orderedAssets.map { PhotoSource.library($0) }
                let patterns = sources.enumerated().map { style.pattern(for: $0.offset, sourceIdentity: $0.element.cacheIdentity) }
                let prepared = try task.cachedReplayClips(sources, seconds: duration, motion: strength, longEdge: edge, patterns: patterns, version: version, root: root, expansion: expansion) { phase in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.session === task, !task.isCancelled else { return }
                        self.preparationStatus = phase
                    }
                }
                let cacheLookupSeconds = Date().timeIntervalSince(cacheLookupStarted)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session === task, !task.isCancelled else { return }
                    self.cachedPhotoCount = prepared.count
                    self.playback.addPreparedReplays(prepared)
                    self.logPlayback("Found \(prepared.count) previously prepared photos for waiting playback, including earlier render settings · lookup \(String(format: "%.2f", cacheLookupSeconds)) seconds")
                }
                // Keep full-quality PhotoKit requests independent of the serial
                // model renderer. A queued iCloud download must not prevent us
                // from preparing another available item. Bound originals on
                // disk to six items and simultaneous downloads/exports to three.
                let downloads = AlbumPreparationQueue<PreparedAlbumItem>(count: sources.count, check: task.check) { index in
                    let source = sources[index]
                    if let cached = task.cachedClip(source, seconds: duration, motion: strength, longEdge: edge, motionPattern: patterns[index], version: version, root: root, expansion: expansion) {
                        return PreparedAlbumItem(.movie(cached))
                    }
                    let progressLock = NSLock()
                    var loadingComplete = false
                    let loadingProgress: (String) -> Void = { phase in
                        progressLock.lock(); defer { progressLock.unlock() }
                        guard !loadingComplete else { return }
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.session === task, !task.isCancelled else { return }
                            self.loadingPhases[index] = phase
                            self.refreshPreparationStatus()
                            self.logPlayback("Loading \(self.itemLabel(index).lowercased()) \(index + 1) · \(phase)")
                        }
                    }
                    defer {
                        // Serialize enqueueing the final removal with progress:
                        // PhotoKit callbacks can race the download's completion.
                        progressLock.lock(); loadingComplete = true
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.session === task else { return }
                            self.loadingPhases.removeValue(forKey: index)
                            self.refreshPreparationStatus()
                        }
                        progressLock.unlock()
                    }
                    return try StorageRecovery.run(at: root, check: task.check, blocked: { message in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.session === task, !task.isCancelled else { return }
                            self.storageBlockages[index] = message
                            self.refreshPreparationStatus()
                            self.logPlayback(message ?? "Storage blockage cleared for item \(index + 1)")
                        }
                    }) {
                        if source.isLibraryVideo {
                            return PreparedAlbumItem(.movie(try task.videoClip(source, version: version, root: root, progress: loadingProgress)))
                        }
                        let scratch = root.appendingPathComponent("Work/Download-\(UUID().uuidString)", isDirectory: true)
                        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                        do {
                            let input = try task.export(source, version: version, into: scratch, progress: loadingProgress)
                            return PreparedAlbumItem(.photo(input), scratch: scratch)
                        } catch {
                            try? FileManager.default.removeItem(at: scratch)
                            throw error
                        }
                    }
                }
                defer { downloads.stop() }
                while let (index, loaded) = try downloads.next() {
                    try task.check()
                    let asset = orderedAssets[index]
                    // Prepare continuously, even when playback is paused. Clips
                    // live on disk and pending playback stores only URLs; the
                    // two players preload just the current and incoming clips.
                    // Each clip's temporary Gaussian scene is freed by task.clip.
                    do {
                        let source = PhotoSource.library(asset)
                        let item = try loaded.get()
                        let renderProgress: (String) -> Void = { phase in
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.session === task, !task.isCancelled else { return }
                                self.preparingPhoto = index
                                self.renderingPhase = phase
                                self.refreshPreparationStatus()
                                self.logPlayback("Preparing \(self.itemLabel(index).lowercased()) \(index + 1) · \(phase)")
                            }
                        }
                        let clip: URL
                        // Retain the owner until the renderer finishes reading
                        // its original; releasing it removes only this scratch.
                        clip = try withExtendedLifetime(item) {
                            switch item.content {
                            case .movie(let url): renderProgress("Ready from cache"); return url
                            case .photo(let input):
                                return try task.clip(source, seconds: duration, motion: strength, longEdge: edge, motionPattern: patterns[index], version: version, root: root, tools: tools, expansion: expansion, preparedInput: input, progress: renderProgress)
                            }
                        }
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.session === task, !task.isCancelled else { return }
                            self.playback.append(clip, number: index)
                            self.preparedPhotoCount += 1
                            self.logPlayback("Queued \(self.itemLabel(index).lowercased()) \(index + 1) · \(self.playback.queuedCount) queued")
                            if self.preparingPhoto == index { self.preparingPhoto = nil; self.renderingPhase = nil }
                            self.refreshPreparationStatus()
                            self.busy = false
                            if self.pendingFullscreen && self.preparationIssue == nil { self.pendingFullscreen = false; self.enterFullscreen() }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // A missing iCloud asset should not prevent the rest of an
                        // album from playing. Report every skipped photo locally.
                        let log = root.appendingPathComponent("Album Errors.log")
                        let line = "\(Date()) \(title) \(asset.mediaType == .video ? "video" : "photo") \(index + 1) [\(asset.localIdentifier)]: \(error as NSError)\n"
                        if let handle = try? FileHandle(forWritingTo: log) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
                        else { try? Data(line.utf8).write(to: log) }
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.session === task else { return }
                            self.skipped += 1
                            if self.preparingPhoto == index { self.preparingPhoto = nil; self.renderingPhase = nil }
                            self.refreshPreparationStatus()
                            self.logPlayback("\(self.itemLabel(index)) \(index + 1) unavailable: \(error.localizedDescription)")
                        }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session === task else { return }
                    self.busy = false; self.playback.finishPreparing()
                    self.preparationStatus = "Preparation complete" + (self.skipped > 0 ? " · \(self.skipped) unavailable" : "")
                    self.preparingPhoto = nil
                    self.renderingPhase = nil; self.loadingPhases.removeAll()
                    self.logPlayback("Preparation complete · \(self.preparedPhotoCount) of \(assets.count) photos ready")
                    if self.skipped == assets.count { self.error = "None of these items could be prepared. Details are in Photos Spatial Slideshow/Album Errors.log in Application Support." }
                }
            } catch is CancellationError { }
            catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session === task else { return }
                    self.stop(); self.error = error.localizedDescription
                }
            }
        }
    }
    func replayAlbum() {
        guard let title = albumTitle else { return }
        if let definition = lastAlbumDefinition {
            var items: [PHAsset] = []
            AlbumLibrary.fetch(definition, includeVideos: includeVideos).enumerateObjects { asset, _, _ in items.append(asset) }
            playAlbum(title, assets: items)
        } else { playAlbum(title, assets: lastAlbum) }
    }
    func build() {
        guard !photos.isEmpty, !busy, let tools = Bundle.main.resourceURL else { return }
        stop(); busy = true
        renderedSettings = currentRenderSettings
        let task = RenderSession(); session = task
        let selected = photos, duration = seconds, strength = motion, size = dimensions
        let style = motionStyle, framingMode = framing, fades = crossfade
        let expandEdges = expandPhotoEdges, extraPercent = expansionPercent, zoomOut = effectiveExpansionZoomOutPercent
        status = "Preparing Photos models…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let expansion = try PhotoExpansionConfiguration.resolve(enabled: expandEdges, percent: extraPercent, zoomOutPercent: zoomOut, tools: tools)
                let job = try Self.support().appendingPathComponent("Renders/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                var scenes: [String] = []
                for (index, photo) in selected.enumerated() {
                    try task.check()
                    DispatchQueue.main.async { [weak self] in if self?.session === task { self?.status = "Creating 3D scene \(index + 1) of \(selected.count)…" } }
                    let scene = job.appendingPathComponent("scene-\(index)", isDirectory: true)
                    let input = try task.expandedInput(photo, configuration: expansion, directory: job.appendingPathComponent("expansion-\(index)"), tools: tools) { phase in
                        DispatchQueue.main.async { [weak self] in if self?.session === task { self?.status = "Photo \(index + 1) · \(phase)" } }
                    }
                    try task.run(tools.appendingPathComponent("GenerateScene"), [input.path, scene.path], log: job.appendingPathComponent("inference-\(index).log"))
                    try task.attachExpansionMetadata(input: input, configuration: expansion, scene: scene)
                    if expansion.enabled { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
                    scenes.append(scene.path)
                }
                DispatchQueue.main.async { [weak self] in if self?.session === task { self?.status = "Rendering camera motion and crossfades…" } }
                let output = job.appendingPathComponent("Spatial Slideshow.mp4")
                try task.run(tools.appendingPathComponent("RenderSlideshow"), [output.path, String(duration), String(strength), size] + scenes, log: job.appendingPathComponent("render.log"), environment: ["SPATIAL_MOTION_PATTERN": String(max(0, style.rawValue)), "SPATIAL_MOTION_VARIETY": style == .varied ? "1" : "0", "SPATIAL_FRAMING": framingMode.rawValue, "SPATIAL_TRANSITION": fades ? "0.8" : "0"])
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session === task else { return }
                    self.busy = false; self.session = nil
                    self.status = "Ready · \(selected.count) photos · \(size) · 30 fps"
                    let overlap = fades ? min(0.8, duration / 3) : 0
                    let step = duration - overlap
                    // Jump past a baked fade so a paused Next shows the new photo.
                    let starts: [Double] = selected.indices.map { index in
                        let time = Double(index) * step
                        return index == 0 ? time : time + overlap
                    }
                    self.playMovie(output, photoStarts: starts)
                }
            } catch is CancellationError { }
            catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.session === task else { return }
                    self.busy = false; self.session = nil; self.status = "Could not create slideshow"; self.error = error.localizedDescription
                }
            }
        }
    }
    func save() {
        guard let movie else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "Spatial Slideshow.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if destination == movie { return }
            try Data(contentsOf: movie, options: .mappedIfSafe).write(to: destination, options: .atomic)
            status = "Saved \(destination.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }
}

struct MoviePreview: NSViewRepresentable {
    let playback: ContinuousPlayback
    let fullscreen: Bool
    let fillScreen: Bool
    let attachWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> SlideshowPlayerView {
        let view = SlideshowPlayerView(frame: .zero)
        view.onWindowChanged = attachWindow; view.bind(to: playback)
        view.setPresentation(fullscreen: fullscreen, fillScreen: fillScreen)
        return view
    }
    func updateNSView(_ view: SlideshowPlayerView, context: Context) {
        view.bind(to: playback)
        view.setPresentation(fullscreen: fullscreen, fillScreen: fillScreen)
    }
}

struct SlideshowView: View {
    private static let appIcon = Bundle.main.url(forResource: "SpatialSlideshow", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    @ObservedObject var model: SlideshowModel
    @State private var browser = false
    var body: some View {
        HStack(spacing: 0) {
            if !model.fullScreen {
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        if let icon = Self.appIcon {
                            Image(nsImage: icon).resizable().interpolation(.high)
                                .frame(width: 64, height: 64).accessibilityHidden(true)
                        } else {
                            Image(systemName: "photo.stack.fill").font(.system(size: 30)).foregroundStyle(.cyan)
                        }
                        Text("Spatial Slideshow").font(.title2.bold())
                        Text("Your photos, with depth and motion.").foregroundStyle(.secondary)
                    }
                    Button { browser = true } label: { Label("Browse Photo Albums…", systemImage: "rectangle.stack").frame(maxWidth: .infinity) }
                        .controlSize(.large).disabled(model.busy || model.albumPlaying)
                    Button(action: model.choose) { Label("Choose Files…", systemImage: "plus").frame(maxWidth: .infinity) }
                        .disabled(model.busy || model.albumPlaying)
                    if let album = model.albumTitle {
                        Text(album).font(.headline)
                        Text(model.albumCountDescription).foregroundStyle(.secondary)
                        if model.cachedPhotoCount > 0 {
                            Text("\(model.cachedPhotoCount) items ready from earlier plays").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !model.photos.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(model.photos.enumerated()), id: \.offset) { index, photo in
                                    HStack { Text("\(index+1)").foregroundStyle(.secondary); Text(photo.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 130)
                    }
                    Divider()
                    SettingsLink {
                        Label("Settings…", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                    }.controlSize(.large)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(model.seconds)) seconds · \(model.motionStyle.title)")
                        Text(model.expandPhotoEdges ? "Expanded edges · \(model.expansionPercent)% per edge" : "Original photo edges")
                        if model.hasPendingRenderSettings {
                            Text("Setting changes apply on the next play")
                                .foregroundStyle(.orange)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if model.busy || model.albumPlaying {
                        Button(action: model.stop) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }.controlSize(.large)
                    } else if model.albumTitle != nil {
                        Button(action: model.replayAlbum) { Label("Play Album", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        Button(action: model.build) { Label("Build Slideshow", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.photos.isEmpty)
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.albumPlaying {
                        Text("\(model.preparedPhotoCount) of \(model.albumCount) \(model.albumVideoCount > 0 ? "items" : "photos") prepared")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let preparation = model.preparationStatus {
                        Text(preparation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let issue = model.preparationIssue {
                        Label(issue, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button { model.playback.previousPhoto() } label: { Label("Previous", systemImage: "backward.end.fill") }
                            .help("Previous photo (←)")
                        Button { model.playback.nextPhoto() } label: { Label("Next", systemImage: "forward.end.fill") }
                            .help("Next photo (→)")
                    }.disabled(model.player.currentItem == nil)
                    Spacer()
                    Text("\(model.framing.title) · Esc to exit\n← Previous · → Next · Space Pause\nActual Photos Reframe model").font(.caption).foregroundStyle(.secondary)
                    Button(action: model.save) { Label("Save MP4…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .disabled(model.movie == nil || model.busy || model.albumPlaying)
                        .help("Saves the rendered photo movie. Music plays live and is not included in the MP4.")
                }.padding(24)
                }.frame(width: 285)
                Divider()
            }
            MoviePreview(playback: model.playback, fullscreen: model.fullScreen, fillScreen: model.framing == .fill, attachWindow: model.attachWindow).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                .overlay(alignment: .top) {
                    if model.fullScreen, let issue = model.preparationIssue {
                        Label(issue, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.callout).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(24).allowsHitTesting(false)
                    }
                }
        }
        .frame(minWidth: model.fullScreen ? 0 : 900, minHeight: model.fullScreen ? 0 : 650)
        .ignoresSafeArea(model.fullScreen ? .all : [], edges: .all)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            if note.object as? NSWindow === model.window { model.fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if note.object as? NSWindow === model.window { model.fullScreen = false }
        }
        .onExitCommand { model.exitFullscreen() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
        .sheet(isPresented: $browser) { AlbumBrowser(library: model.library, shuffle: $model.shuffleAlbum, includeVideos: $model.includeVideos, play: model.playAlbum) }
        .alert("Slideshow error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@main
struct SpatialSlideshowApp: App {
    @StateObject private var model = SlideshowModel()
    var body: some Scene {
        Window("Spatial Slideshow", id: "slideshow") { SlideshowView(model: model) }.defaultSize(width: 1100, height: 850)
            .commands {
                CommandMenu("Playback") {
                    Button("Previous Photo") { model.playback.previousPhoto() }
                    Button("Next Photo") { model.playback.nextPhoto() }
                    Divider()
                    Button("Play / Pause") { model.playback.togglePlayback() }
                }
            }
        Settings { SlideshowOptions(model: model) }
    }
}
