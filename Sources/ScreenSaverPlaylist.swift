import Foundation

struct ScreenSaverClip: Codable, Equatable {
    let id: String
    let relativePath: String
    var isScene: Bool? = nil
    var fallbackRelativePath: String? = nil
}

struct ScreenSaverPlaylist: Codable, Equatable {
    var schema = 1
    var enabled = true
    var selectionID: String
    var title: String
    var shuffle: Bool
    var fillScreen: Bool
    var crossfade: Bool
    var clips: [ScreenSaverClip]
    var liveSettings: LiveRenderSettings? = nil

    func playableClips(root: URL) -> [(ScreenSaverClip, URL)] {
        var seen = Set<String>()
        return clips.compactMap { clip in
            guard seen.insert(clip.id).inserted else { return nil }
            if clip.isScene == true {
                if liveSettings != nil, let scene = ScreenSaverStorage.sceneURL(clip.relativePath, root: root), SceneCache.validateScene(scene) {
                    return (clip, scene)
                }
                guard let fallback = clip.fallbackRelativePath,
                      let url = ScreenSaverStorage.clipURL(fallback, root: root),
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
                return (ScreenSaverClip(id: clip.id, relativePath: fallback), url)
            }
            guard let url = ScreenSaverStorage.clipURL(clip.relativePath, root: root),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
            return (clip, url)
        }
    }
}

enum ScreenSaverStorage {
    // The system screen saver runs in a container. Resolve the account's home,
    // not that container's Library, to read the app's prepared-media catalog.
    static var root: URL {
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/Photos Spatial Slideshow", isDirectory: true)
    }
    static func manifestURL(root: URL) -> URL { root.appendingPathComponent("Screen Saver/Playlist.json") }

    static func clipURL(_ relativePath: String, root: URL) -> URL? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains("."), !parts.contains(""),
              parts.first == "Clip Cache" || parts.first == "Renders" else { return nil }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(resolvedRoot.path + "/"), ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    static func sceneURL(_ relativePath: String, root: URL) -> URL? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "Scene Cache", parts[1] == Substring(SceneCache.pipelineVersion),
              parts[2].count == 64, parts[2].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let url = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        let cache = SceneCache.directory(root: root).resolvingSymlinksInPath().standardizedFileURL
        guard url.deletingLastPathComponent() == cache else { return nil }
        return url
    }
    static func scene(id: String, url: URL, fallback: URL?, root: URL) -> ScreenSaverClip? {
        let prefix = root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
        guard sceneURL(relative, root: root) != nil else { return nil }
        return ScreenSaverClip(id: id, relativePath: relative, isScene: true,
                               fallbackRelativePath: fallback.flatMap { clip(id: id, url: $0, root: root)?.relativePath })
    }

    static func clip(id: String, url: URL, root: URL) -> ScreenSaverClip? {
        let prefix = root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
        guard clipURL(relative, root: root) != nil else { return nil }
        return ScreenSaverClip(id: id, relativePath: relative)
    }

    static func read(root: URL) throws -> ScreenSaverPlaylist {
        let playlist = try JSONDecoder().decode(ScreenSaverPlaylist.self, from: Data(contentsOf: manifestURL(root: root)))
        guard playlist.schema == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return playlist
    }

    static func write(_ playlist: ScreenSaverPlaylist, root: URL) throws {
        let url = manifestURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(playlist).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func merging(_ playlist: ScreenSaverPlaylist, orderedIDs: [String], prepared: [ScreenSaverClip]) -> ScreenSaverPlaylist {
        var result = playlist
        var byID: [String: ScreenSaverClip] = [:]
        for clip in playlist.clips + prepared { byID[clip.id] = clip }
        var seen = Set<String>()
        result.clips = orderedIDs.filter { seen.insert($0).inserted }.compactMap { byID[$0] }
        return result
    }
}
