import Foundation
import CryptoKit

/// Snapshot once per play/build so UI changes cannot mix processing settings.
struct PhotoExpansionConfiguration {
    let percent: Int
    let modelFingerprint: String
    var zoomOutPercent: Int = 0
    static let disabled = PhotoExpansionConfiguration(percent: 0, modelFingerprint: "")
    var enabled: Bool { percent > 0 }
    var allowedZoomOutPercent: Int { min(max(0, zoomOutPercent), min(20, max(0, percent)) * 2) }

    func cacheIdentity(_ sourceIdentity: String) -> String {
        guard enabled else { return sourceIdentity } // Preserve existing caches exactly.
        // Version the expanded framing separately: old clips reveal the whole
        // generated canvas and must not be replayed after the composition fix.
        let baseline = sourceIdentity + "|apple-cleanup-motion-v2|\(percent)|\(modelFingerprint)"
        // Zero retains the existing original-composition cache. Nonzero
        // allowances isolate both exact hits and waiting replay variants.
        return allowedZoomOutPercent == 0 ? baseline : baseline + "|zoom-out-\(allowedZoomOutPercent)"
    }

    static func resolve(enabled: Bool, percent: Int, zoomOutPercent: Int = 0, tools: URL) throws -> Self {
        guard enabled else { return .disabled }
        let helper = tools.appendingPathComponent("ExpandPhoto")
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: helper.path) else {
            throw failure("The photo expansion helper is missing. Rebuild Spatial Slideshow.")
        }
        let assetRoot = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_MagicCleanup/purpose_auto")
        let assets = (try? manager.contentsOfDirectory(at: assetRoot, includingPropertiesForKeys: nil)) ?? []
        let candidates = assets.filter { $0.pathExtension == "asset" }.map { $0.appendingPathComponent(".AssetData") }.filter {
            manager.fileExists(atPath: $0.appendingPathComponent("inpainting.mlmodelc").path) &&
            manager.fileExists(atPath: $0.appendingPathComponent("refinement.mlmodelc").path)
        }
        guard candidates.count == 1, let model = candidates.first else {
            throw failure("Apple’s Fast Clean Up models are unavailable. Open Clean Up in Photos to download them, or turn off Expand Photo Edges.")
        }
        var identity = "cleanup-composite-v1|" + ProcessInfo.processInfo.operatingSystemVersionString + "|" + model.path
        for file in [helper, model.appendingPathComponent("metadata.json"),
                     model.appendingPathComponent("inpainting.mlmodelc/coremldata.bin"),
                     model.appendingPathComponent("refinement.mlmodelc/coremldata.bin")] {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            identity += "|" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(percent: min(20, max(1, percent)), modelFingerprint: fingerprint, zoomOutPercent: zoomOutPercent)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoExpansion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension RenderSession {
    func expandedInput(_ input: URL, configuration: PhotoExpansionConfiguration, directory: URL,
                       tools: URL, progress: (String) -> Void) throws -> URL {
        guard configuration.enabled else { return input }
        try check()
        progress("Expanding photo edges · \(configuration.percent)% per edge…")
        try run(tools.appendingPathComponent("ExpandPhoto"), [input.path, directory.path, String(configuration.percent)],
                log: directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".log"))
        let expanded = directory.appendingPathComponent("expanded.png")
        guard FileManager.default.fileExists(atPath: expanded.path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("expansion.json").path) else {
            throw NSError(domain: "PhotoExpansion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Clean Up did not finish expanding this photo."])
        }
        return expanded
    }

    func attachExpansionMetadata(input: URL, configuration: PhotoExpansionConfiguration, scene: URL) throws {
        guard configuration.enabled else { return }
        let data = try Data(contentsOf: input.deletingLastPathComponent().appendingPathComponent("expansion.json"))
        guard var metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PhotoExpansion", code: 3, userInfo: [NSLocalizedDescriptionKey: "The expanded photo metadata is invalid."])
        }
        metadata["zoom_out_percent"] = configuration.allowedZoomOutPercent
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: scene.appendingPathComponent("expansion.json"), options: .atomic)
    }
}
