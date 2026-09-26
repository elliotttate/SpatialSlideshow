import Foundation
import AVFoundation

@main
struct VideoClipCacheTest {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments[2] == "--lookup" {
            let url = VideoClipCache.url(sourceIdentity: "fixture-sdr", version: .current, root: root)
            precondition(VideoClipCache.existing(url) != nil, "A new process must find the saved video")
            print("PASS video cache survives a process restart")
            return
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        let hdrInput = URL(fileURLWithPath: CommandLine.arguments[3])
        let session = RenderSession()
        var checks: [String] = []
        func check(_ value: Bool, _ description: String) {
            precondition(value, description); checks.append(description)
        }
        let asset = AVURLAsset(url: input)
        let output = try session.cacheVideoAsset(PreparedVideoAsset(asset: asset), sourceIdentity: "fixture-sdr", version: .current, root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let invalidAsset = AVURLAsset(url: root.appendingPathComponent("does-not-exist.mov"))
        let repeated = try RenderSession().cacheVideoAsset(PreparedVideoAsset(asset: invalidAsset), sourceIdentity: "fixture-sdr", version: .current, root: root)
        let repeatAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let originalDate = attributes[.modificationDate] as? Date
        let repeatDate = repeatAttributes[.modificationDate] as? Date
        check(output == repeated && originalDate == repeatDate, "Cache hits return the existing movie without requesting or exporting the asset again")
        check(VideoClipCache.url(sourceIdentity: "fixture-sdr", version: .original, root: root) != output, "Original and current edits have independent video cache entries")
        check(VideoClipCache.url(sourceIdentity: "fixture-sdr-modified", version: .current, root: root) != output, "Source modification invalidates the video cache")
        let empty = VideoClipCache.url(sourceIdentity: "empty", version: .current, root: root)
        try Data().write(to: empty)
        check(VideoClipCache.existing(empty) == nil, "An empty video cannot become a cache hit")
        try FileManager.default.removeItem(at: empty)

        let hdr = try session.cacheVideoAsset(PreparedVideoAsset(asset: AVURLAsset(url: hdrInput)), sourceIdentity: "fixture-hdr", version: .current, root: root)
        let edited = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: 0.25, preferredTimescale: 600), duration: CMTime(seconds: 1, preferredTimescale: 600))
        for track in try await asset.load(.tracks) {
            guard let destination = edited.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try destination.insertTimeRange(range, of: track, at: .zero)
            destination.preferredTransform = try await track.load(.preferredTransform)
        }
        let videoComposition = AVVideoComposition(propertiesOf: edited)
        let editedMovie = try session.cacheVideoAsset(PreparedVideoAsset(asset: edited, videoComposition: videoComposition), sourceIdentity: "fixture-edit", version: .current, root: root)
        let editedDuration = try await AVURLAsset(url: editedMovie).load(.duration)
        check(abs(editedDuration.seconds - 1) < 0.05, "A composed edit keeps the edited duration instead of the source duration")

        let cancelled = RenderSession()
        let cancelledKey = "cancelled-export"
        let start = Date()
        do {
            _ = try cancelled.cacheVideoAsset(PreparedVideoAsset(asset: edited, videoComposition: videoComposition), sourceIdentity: cancelledKey, version: .current, root: root) { text in
                if text == "Preparing edited video…" {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { cancelled.cancel() }
                }
            }
            preconditionFailure("Cancelling an active export must throw")
        } catch is CancellationError {}
        check(Date().timeIntervalSince(start) < 2, "Cancelling an active export returns promptly")
        check(VideoClipCache.existing(VideoClipCache.url(sourceIdentity: cancelledKey, version: .current, root: root)) == nil, "Cancelled exports never publish a movie")
        let entries = try FileManager.default.contentsOfDirectory(at: VideoClipCache.directory(root: root), includingPropertiesForKeys: nil)
        check(!entries.contains { $0.lastPathComponent.hasPrefix(".work-") }, "Cancelled and successful exports remove only their temporary work")
        check(VideoClipCache.existing(output) != nil && VideoClipCache.existing(hdr) != nil, "Cancellation preserves other completed cached videos")

        let preCancelled = RenderSession(); preCancelled.cancel()
        do {
            _ = try preCancelled.videoClip(.file(input), version: .current, root: root)
            preconditionFailure("A cancelled request must not start")
        } catch is CancellationError { checks.append("An already cancelled session never requests or exports a video") }
        let result: [String: Any] = ["passed": true, "checks": checks, "sdr": output.path, "hdr": hdr.path, "edited": editedMovie.path]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS \(checks.count) video cache checks")
    }
}
