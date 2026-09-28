import AppKit
import Combine

final class ScreenSaverController: ObservableObject {
    static let bundleIdentifier = "local.photos-spatial-slideshow.screensaver"
    @Published private(set) var playlist: ScreenSaverPlaylist?
    @Published private(set) var installed = false
    @Published private(set) var currentTitle: String?
    @Published private(set) var availableCount = 0
    @Published var message: String?
    private var selectionID: String?
    private var orderedIDs: [String] = []
    private var currentLiveSettings: LiveRenderSettings?
    private var prepared: [String: ScreenSaverClip] = [:]
    private let root: URL
    var enabled: Bool { playlist?.enabled == true }
    var readyCount: Int { playlist?.playableClips(root: root).count ?? 0 }
    private var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/Spatial Slideshow.saver")
    }

    init(root: URL = ScreenSaverStorage.root) {
        self.root = root
        playlist = try? ScreenSaverStorage.read(root: root)
        installed = Bundle(url: installedURL)?.bundleIdentifier == Self.bundleIdentifier
    }
    func clearCurrentSelection() {
        selectionID = nil; currentTitle = nil; orderedIDs = []; prepared = [:]; availableCount = 0
    }

    func beginSelection(id: String, title: String, orderedIDs: [String], liveSettings: LiveRenderSettings? = nil) {
        selectionID = id; currentTitle = title; self.orderedIDs = orderedIDs
        currentLiveSettings = liveSettings
        prepared = [:]; availableCount = 0
        updateSelectedPlaylist()
    }
    func add(_ items: [(String, URL)]) {
        for (id, url) in items {
            if let clip = ScreenSaverStorage.clip(id: id, url: url, root: root) { prepared[id] = clip }
        }
        availableCount = prepared.count
        updateSelectedPlaylist()
    }
    func addScenes(_ items: [(String, URL, URL?)]) {
        for (id, url, fallback) in items {
            if let scene = ScreenSaverStorage.scene(id: id, url: url, fallback: fallback, root: root) { prepared[id] = scene }
        }
        availableCount = prepared.count
        updateSelectedPlaylist()
    }
    func updateLiveSettings(_ settings: LiveRenderSettings?) {
        currentLiveSettings = settings
        updateSelectedPlaylist()
    }
    func useCurrent(shuffle: Bool, fillScreen: Bool, crossfade: Bool) {
        guard let selectionID, let title = currentTitle else { return }
        let oldClips = playlist?.selectionID == selectionID ? playlist!.clips : []
        let selected = ScreenSaverPlaylist(selectionID: selectionID, title: title, shuffle: shuffle,
                                          fillScreen: fillScreen, crossfade: crossfade, clips: oldClips, liveSettings: currentLiveSettings)
        guard save(ScreenSaverStorage.merging(selected, orderedIDs: orderedIDs, prepared: Array(prepared.values))) else { return }
        if readyCount == 0 { message = "Selected. Play this slideshow to prepare its first photo; new clips will appear automatically." }
        else { message = "Ready. Install the screen saver, then choose Wallpaper → Screen Saver → Custom → Other → Spatial Slideshow in macOS Settings." }
    }
    func setEnabled(_ enabled: Bool) {
        guard var playlist else { return }
        playlist.enabled = enabled; save(playlist)
    }
    func updatePresentation(shuffle: Bool, fillScreen: Bool, crossfade: Bool) {
        guard var playlist else { return }
        playlist.shuffle = shuffle; playlist.fillScreen = fillScreen; playlist.crossfade = crossfade
        save(playlist)
    }
    private func updateSelectedPlaylist() {
        guard var playlist, playlist.selectionID == selectionID else { return }
        playlist.liveSettings = currentLiveSettings
        save(ScreenSaverStorage.merging(playlist, orderedIDs: orderedIDs, prepared: Array(prepared.values)))
    }
    @discardableResult
    private func save(_ value: ScreenSaverPlaylist) -> Bool {
        do { try ScreenSaverStorage.write(value, root: root); playlist = value; return true }
        catch { message = "Could not update the screen saver: \(error.localizedDescription)"; return false }
    }

    func install() {
        guard let source = Bundle.main.url(forResource: "Spatial Slideshow", withExtension: "saver"),
              Bundle(url: source)?.bundleIdentifier == Self.bundleIdentifier else {
            message = "This app is missing its screen saver component. Reinstall the complete app bundle."; return
        }
        let manager = FileManager.default, destination = installedURL
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path), Bundle(url: destination)?.bundleIdentifier != Self.bundleIdentifier {
                message = "A different screen saver already uses this filename. Rename it in Library/Screen Savers before installing."; return
            }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".spatial-install-\(UUID().uuidString).saver")
            try manager.copyItem(at: source, to: staging)
            defer { try? manager.removeItem(at: staging) }
            if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staging) }
            else { try manager.moveItem(at: staging, to: destination) }
            installed = true
            message = "Installed for your user. In macOS Settings, choose Wallpaper → Screen Saver → Custom → Other → Spatial Slideshow. If Settings was already open, close and reopen it to refresh the list."
            openSettings()
        } catch { message = "Could not install the screen saver: \(error.localizedDescription)" }
    }
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
