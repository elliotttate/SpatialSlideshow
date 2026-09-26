import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// A local audio playlist, independent of the rendered photo clips.
/// Call startIfSelected/pause/stop with the corresponding slideshow actions.
final class MusicPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tracks: [URL] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = false
    @Published var error: String?
    @Published var volume: Double {
        didSet {
            let value = min(1, max(0, volume))
            audioPlayer?.volume = Float(value)
            defaults.set(value, forKey: "music.volume")
        }
    }
    @Published var loopPlaylist: Bool {
        didSet { defaults.set(loopPlaylist, forKey: "music.loopPlaylist") }
    }
    private let defaults: UserDefaults
    private var audioPlayer: AVAudioPlayer?
    private var reachedPlaylistEnd = false
    private var failedTracks = Set<URL>()

    var hasSelection: Bool { !tracks.isEmpty }
    var currentTrackName: String {
        guard tracks.indices.contains(currentIndex) else { return "No music selected" }
        return tracks[currentIndex].deletingPathExtension().lastPathComponent
    }
    var playlistDescription: String {
        tracks.count > 1 ? "Track \(currentIndex + 1) of \(tracks.count)" : "Local audio"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        volume = defaults.object(forKey: "music.volume") == nil ? 0.65 : defaults.double(forKey: "music.volume")
        loopPlaylist = defaults.object(forKey: "music.loopPlaylist") == nil || defaults.bool(forKey: "music.loopPlaylist")
        super.init()
        tracks = (defaults.stringArray(forKey: "music.files") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.title = "Choose music for the slideshow"
        panel.message = "Choose one or more local audio files. Tracks play in the selected order."
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        replacePlaylist(panel.urls)
    }

    /// Also useful for dropped files or a future playlist browser.
    func replacePlaylist(_ urls: [URL]) {
        let resume = isPlaying
        stop()
        tracks = urls.filter(\.isFileURL)
        currentIndex = 0
        reachedPlaylistEnd = false
        failedTracks = []
        error = urls.count == tracks.count ? nil : "Music must be selected from local audio files."
        defaults.set(tracks.map(\.path), forKey: "music.files")
        if resume { startIfSelected() }
    }

    func startIfSelected() {
        guard hasSelection, !isPlaying else { return }
        failedTracks = []
        if reachedPlaylistEnd {
            audioPlayer = nil
            currentIndex = 0
            reachedPlaylistEnd = false
        }
        if let audioPlayer {
            if audioPlayer.play() { isPlaying = true }
            else { error = "Could not play \(currentTrackName). Choose another audio file." }
        } else {
            playTrack(startingAt: currentIndex)
        }
    }

    func toggle() { isPlaying ? pause() : startIfSelected() }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
    }

    /// Stop rewinds the playlist; pause retains the current track position.
    func stop() {
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        isPlaying = false
        currentIndex = 0
        reachedPlaylistEnd = false
    }

    func clear() {
        stop()
        tracks = []
        error = nil
        defaults.removeObject(forKey: "music.files")
    }

    func nextTrack() {
        guard !tracks.isEmpty else { return }
        let wasPlaying = isPlaying
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        isPlaying = false
        currentIndex = (currentIndex + 1) % tracks.count
        reachedPlaylistEnd = false
        if wasPlaying { playTrack(startingAt: currentIndex) }
    }

    private func playTrack(startingAt index: Int) {
        guard !tracks.isEmpty else { return }
        // Try each track at most once, so missing or unsupported files cannot
        // cause a retry loop even when Repeat Playlist is enabled.
        let indices = loopPlaylist
            ? (0..<tracks.count).map { (index + $0) % tracks.count }
            : Array(index..<tracks.count)
        var failures: [String] = []
        for candidate in indices where !failedTracks.contains(tracks[candidate]) {
            currentIndex = candidate
            do {
                let player = try AVAudioPlayer(contentsOf: tracks[candidate])
                player.delegate = self
                player.volume = Float(min(1, max(0, volume)))
                guard player.prepareToPlay(), player.play() else {
                    throw NSError(domain: "MusicPlayback", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The audio decoder could not start."])
                }
                audioPlayer = player
                isPlaying = true
                reachedPlaylistEnd = false
                if !failures.isEmpty { error = "Skipped unavailable music: " + failures.joined(separator: ", ") }
                return
            } catch {
                failedTracks.insert(tracks[candidate])
                failures.append(tracks[candidate].lastPathComponent)
            }
        }
        audioPlayer = nil
        isPlaying = false
        let unavailable = failures.isEmpty ? "the selected music" : failures.joined(separator: ", ")
        error = "Could not play " + unavailable + ". Choose available, unprotected audio files."
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        audioPlayer?.delegate = nil
        audioPlayer = nil
        isPlaying = false
        if !flag {
            error = "Playback stopped unexpectedly for \(currentTrackName)."
            if tracks.indices.contains(currentIndex) { failedTracks.insert(tracks[currentIndex]) }
        }
        let next = currentIndex + 1
        if next < tracks.count { playTrack(startingAt: next) }
        else if loopPlaylist { playTrack(startingAt: 0) }
        else { reachedPlaylistEnd = true }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer else { return }
        self.error = "Could not decode \(currentTrackName): \(error?.localizedDescription ?? "Unsupported audio data")"
        if tracks.indices.contains(currentIndex) { failedTracks.insert(tracks[currentIndex]) }
        audioPlayerDidFinishPlaying(player, successfully: true)
    }
}

/// Place inside the app's Options menu; it adds no fullscreen overlay.
struct MusicOptions: View {
    @ObservedObject var music: MusicPlayback

    var body: some View {
        Button("Choose Music…", action: music.chooseMusic)
        if music.hasSelection {
            Text(music.currentTrackName)
            Button(music.isPlaying ? "Pause Music" : "Play Music", action: music.toggle)
            Button("Next Track", action: music.nextTrack).disabled(music.tracks.count < 2)
            Button("Stop Music", action: music.stop)
            Toggle("Repeat Playlist", isOn: $music.loopPlaylist)
            Menu("Music Volume") {
                ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
                    Button("\(percent)%") { music.volume = Double(percent) / 100 }
                }
            }
            Divider()
            Button("Remove Music", action: music.clear)
        }
        if let error = music.error {
            Divider()
            Text(error)
        }
    }
}

/// Optional compact sidebar controls; parent decides where they are shown.
struct MusicControls: View {
    @ObservedObject var music: MusicPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Music", systemImage: "music.note")
                Spacer()
                Button("Choose…", action: music.chooseMusic)
            }
            if music.hasSelection {
                Text(music.currentTrackName).lineLimit(1).help(music.currentTrackName)
                HStack {
                    Button(action: music.toggle) {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    }.help(music.isPlaying ? "Pause music" : "Play music")
                    Button(action: music.nextTrack) { Image(systemName: "forward.end.fill") }
                        .disabled(music.tracks.count < 2).help("Next music track")
                    Text(music.playlistDescription).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $music.volume, in: 0...1).accessibilityLabel("Music volume")
                    Image(systemName: "speaker.wave.3.fill")
                }
                Toggle("Repeat playlist", isOn: $music.loopPlaylist).font(.caption)
            }
            if let error = music.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Dismiss music error") { music.error = nil }.font(.caption)
            }
        }
    }
}
