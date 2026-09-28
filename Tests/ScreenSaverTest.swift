import AppKit
import AVKit
import ScreenSaver

@main
struct ScreenSaverTest {
    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SpatialSaverTest-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("Clip Cache/Color Managed v1")
        try manager.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        var clips: [(String, URL)] = []
        for index in 0..<3 {
            let url = cache.appendingPathComponent("\(index).mp4")
            try manager.copyItem(at: fixture, to: url)
            clips.append((String(index),url))
        }
        let controller = ScreenSaverController(root: root)
        controller.beginSelection(id: "album-a", title: "Synthetic", orderedIDs: ["0","1","2"])
        controller.add(Array(clips.prefix(2)))
        controller.useCurrent(shuffle: false, fillScreen: true, crossfade: true)
        precondition(controller.readyCount == 2)
        let restarted = ScreenSaverController(root: root)
        precondition(restarted.readyCount == 2 && restarted.enabled)
        controller.add([clips[2]])
        let saved = try ScreenSaverStorage.read(root: root)
        precondition(saved.clips.map(\.id) == ["0","1","2"] && saved.fillScreen && saved.crossfade)
        controller.beginSelection(id: "album-b", title: "Unselected", orderedIDs: ["0"])
        controller.add([clips[0]])
        let unchanged = try ScreenSaverStorage.read(root: root)
        precondition(unchanged == saved, "Playing a different album must not replace the selected screen saver")
        controller.beginSelection(id: "album-a", title: "Synthetic", orderedIDs: ["2","0"])
        precondition(controller.playlist?.clips.map(\.id) == ["2","0"], "Album removals must leave the screen saver too")
        precondition(ScreenSaverStorage.clipURL("../outside.mp4", root: root) == nil)
        precondition(ScreenSaverStorage.clipURL("/tmp/outside.mp4", root: root) == nil)
        precondition(ScreenSaverStorage.clipURL("Clip Cache/../../outside.mp4", root: root) == nil)
        let link = cache.appendingPathComponent("escape.mp4")
        try manager.createSymbolicLink(at: link, withDestinationURL: fixture)
        precondition(ScreenSaverStorage.clipURL("Clip Cache/Color Managed v1/escape.mp4", root: root) == nil)
        let mode = try manager.attributesOfItem(atPath: ScreenSaverStorage.manifestURL(root: root).path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        let sceneInput = root.appendingPathComponent("synthetic-scene")
        try manager.createDirectory(at: sceneInput, withIntermediateDirectories: true)
        var buffers: [String: Any] = [:]
        for (name, components) in ["alphas": 1, "positions": 3, "scales": 3, "rotations": 4, "colors": 3] {
            buffers[name] = ["width": 64, "height": components * 2, "bytesPerRow": 128, "pixelFormat": 1_278_226_536]
            try Data(repeating: 1, count: 256 * components).write(to: sceneInput.appendingPathComponent(name + ".bin"))
        }
        try JSONSerialization.data(withJSONObject: ["width": 1280, "height": 720, "buffers": buffers])
            .write(to: sceneInput.appendingPathComponent("scene.json"))
        let scene = try SceneCache.store(sceneInput, sourceIdentity: "synthetic", version: "original", root: root)
        let live = LiveRenderSettings(seconds: 8, strength: 2, pattern: -1, zoomOut: 10, longEdge: 3840)
        controller.beginSelection(id: "live", title: "Synthetic Live", orderedIDs: ["live-photo"], liveSettings: live)
        controller.addScenes([("live-photo", scene, clips[0].1)])
        controller.useCurrent(shuffle: false, fillScreen: false, crossfade: true)
        let liveSaved = try ScreenSaverStorage.read(root: root)
        precondition(liveSaved.liveSettings == live && liveSaved.playableClips(root: root).first?.1 == scene)
        var clipOnly = liveSaved; clipOnly.liveSettings = nil
        precondition(clipOnly.playableClips(root: root).first?.1 == clips[0].1, "Disabling live rendering resolves the saved clip fallback")
        precondition(ScreenSaverStorage.sceneURL("Scene Cache/../outside", root: root) == nil)
        try manager.removeItem(at: scene)
        precondition(liveSaved.playableClips(root: root).first?.1 == clips[0].1, "An evicted scene resolves to its saved clip")
        try ScreenSaverStorage.write(saved, root: root)
        print("PASS persistent selection, incremental clips, album isolation/removals, local paths and private manifest")

        let view = SpatialSlideshowScreenSaverView(frame: NSRect(x:0,y:0,width:640,height:360), isPreview: true, mediaRoot: root)!
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view; window.orderFrontRegardless()
        view.startAnimation(); view.layoutSubtreeIfNeeded()
        var visits: [String] = [], blends=0, drawnFrames=0, blackFrames=0
        // Multi-second clips catch a frame disappearing after one second;
        // one-second fixtures only exercised the overlap between photos.
        let deadline=Date().addingTimeInterval(34)
        while Date() < deadline {
            pump(0.025)
            view.animateOneFrame()
            let layers=view.playbackLayers
            if layers.count == 2,
               layers.contains(where: { $0.opacity > 0 && $0.opacity < 1 }) { blends += 1 }
            if let visible=layers.max(by: { $0.opacity < $1.opacity }),
               let asset=visible.player?.currentItem?.asset as? AVURLAsset {
                let name=asset.url.lastPathComponent
                if visits.last != name { visits.append(name) }
            }
            if let frame = view.renderedFrameSnapshot() {
                let bitmap = NSBitmapImageRep(cgImage: frame)
                let color = bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                let bright = max(color.redComponent, color.greenComponent, color.blueComponent) > 0.1
                if bright { drawnFrames += 1 }
                else if drawnFrames > 0 { blackFrames += 1 }
            }
        }
        print("VISITS",visits,"BLENDS",blends)
        precondition(Array(visits.prefix(6)) == ["0.mp4","1.mp4","2.mp4","0.mp4","1.mp4","2.mp4"], "No early repeats; unshuffled saver must cycle in order: \(visits)")
        precondition(blends > 5, "Screen saver must visibly dissolve")
        precondition(drawnFrames > 500 && blackFrames == 0, "Composited frames must stay visible for entire clips and transitions: \(drawnFrames) visible, \(blackFrames) black")
        precondition(view.renderedFrameCount > 1200, "GPU rendering must run faster than the old 30 fps drawing path: \(view.renderedFrameCount) frames")
        let layers=view.playbackLayers
        precondition(layers.count == 2 && layers.allSatisfy { $0.videoGravity == .resizeAspectFill && $0.frame == view.bounds && $0.player?.volume == 0 })
        view.frame = NSRect(x:0,y:0,width:1280,height:720); view.layoutSubtreeIfNeeded()
        precondition(layers.allSatisfy { $0.frame == view.bounds })
        view.stopAnimation(); pump(0.2)
        precondition(layers.allSatisfy { $0.player?.rate == 0 && $0.player?.currentItem == nil && $0.superlayer == nil })
        view.startAnimation(); pump(0.6)
        view.animateOneFrame()
        precondition(view.playbackLayers.contains { $0.player?.currentItem?.status == .readyToPlay })
        view.stopAnimation()
        controller.setEnabled(false)
        view.startAnimation(); pump(0.2)
        precondition(view.playbackLayers.isEmpty, "Disabled saver must not show private media")
        view.stopAnimation(); window.close()
        print("PASS native saver view: cyclic playback, \(blends) dissolve samples, \(drawnFrames) composited frames without black gaps, silent audio, resizing, stop/restart and disable")
    }
}
