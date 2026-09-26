import Foundation
import CoreImage
import CoreML
import CoreVideo
import CryptoKit
import PhotosGenerativeServices
import Darwin

private let expansionProtocolVersion = 1
private let expansionBackend = "PhotosGenerativeServices.InpaintGANPipeline"
private let expansionTimeoutSeconds: UInt32 = 180

private struct ExpansionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct CleanupModels {
    let root: URL
    let identity: [String: Any]

    static func installed() throws -> CleanupModels {
        let assets = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_MagicCleanup/purpose_auto", isDirectory: true)
        let names = ["inpainting.mlmodelc", "refinement.mlmodelc"]
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "asset" }
                .map { $0.appendingPathComponent(".AssetData", isDirectory: true) }
                .filter { root in names.allSatisfy { name in
                    FileManager.default.isReadableFile(atPath: root.appendingPathComponent(name).path)
                } }
        } catch {
            throw ExpansionError(message: "Apple Photos Fast Clean Up models are not installed or readable: \(error.localizedDescription)")
        }
        guard candidates.count == 1, let root = candidates.first else {
            throw ExpansionError(message: candidates.isEmpty
                ? "Apple Photos Fast Clean Up models are not installed or readable."
                : "Multiple installed Fast Clean Up model pairs were found; refusing to choose an unknown version.")
        }
        for name in names {
            guard FileManager.default.isReadableFile(atPath: root.appendingPathComponent(name).appendingPathComponent("model.specialization.bundle").path) else {
                throw ExpansionError(message: "The installed \(name) does not contain its precompiled specialization bundle.")
            }
        }
        // Registered assets are immutable. Include their metadata and compiled
        // model descriptors in cache identity without reading large weights.
        let metadataFiles: [(String, URL)] = [
            ("Info.plist", root.deletingLastPathComponent().appendingPathComponent("Info.plist")),
            ("metadata.json", root.appendingPathComponent("metadata.json")),
            ("inpainting/coremldata.bin", root.appendingPathComponent("inpainting.mlmodelc/coremldata.bin")),
            ("refinement/coremldata.bin", root.appendingPathComponent("refinement.mlmodelc/coremldata.bin"))
        ]
        var hash = SHA256()
        var fileHashes: [String: String] = [:]
        for (name, url) in metadataFiles {
            let data = try Data(contentsOf: url)
            hash.update(data: Data("\(name)\u{0}\(data.count)\u{0}".utf8))
            hash.update(data: data)
            fileHashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let identity: [String: Any] = [
            "schema": 1,
            "helper_protocol_version": expansionProtocolVersion,
            "backend": expansionBackend,
            "model_root": root.path,
            "model_metadata_sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(),
            "model_metadata_files_sha256": fileHashes,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "use_precompiled_e5_bundle": true,
            "refinement": true
        ]
        return CleanupModels(root: root, identity: identity)
    }

    func load() throws -> InpaintGANPipeline {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard configuration.responds(to: NSSelectorFromString("setUsePrecompiledE5Bundle:")) else {
            throw ExpansionError(message: "This macOS version does not support the installed precompiled Fast Clean Up models.")
        }
        // Photos' NUMLModelRegistry sets this flag when the model contains
        // model.specialization.bundle; ordinary respecialization is incorrect.
        configuration.setValue(true, forKey: "usePrecompiledE5Bundle")
        let inpainting = try MLModel(contentsOf: root.appendingPathComponent("inpainting.mlmodelc"), configuration: configuration)
        let refinement = try MLModel(contentsOf: root.appendingPathComponent("refinement.mlmodelc"), configuration: configuration)
        var pipeline = InpaintGANPipeline(cleanupModel: inpainting)
        pipeline.refinementModel = refinement
        return pipeline
    }
}

private struct ExpansionGeometry {
    let sourceWidth: Int
    let sourceHeight: Int
    let padX: Int
    let padY: Int
    let modelWidth: Int
    let modelHeight: Int
    let modelPadX: Int
    let modelPadY: Int

    init(width: Int, height: Int, percent: Int) throws {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000 else {
            throw ExpansionError(message: "The photo has unsupported dimensions.")
        }
        sourceWidth = width
        sourceHeight = height
        padX = max(1, Int((Double(width) * Double(percent) / 100).rounded()))
        padY = max(1, Int((Double(height) * Double(percent) / 100).rounded()))
        let scale = min(1, 1024 / Double(max(width, height)))
        modelWidth = max(1, Int((Double(width) * scale).rounded()))
        modelHeight = max(1, Int((Double(height) * scale).rounded()))
        // Round model padding outward. When restoring source resolution this
        // guarantees coverage of the requested canvas without an empty edge.
        modelPadX = max(1, Int(ceil(Double(padX) * Double(modelWidth) / Double(width))))
        modelPadY = max(1, Int(ceil(Double(padY) * Double(modelHeight) / Double(height))))
    }

    var outputWidth: Int { sourceWidth + 2 * padX }
    var outputHeight: Int { sourceHeight + 2 * padY }
    var sourceBox: CGRect { CGRect(x: padX, y: padY, width: sourceWidth, height: sourceHeight) }
    var outputExtent: CGRect { CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight) }
    var modelSourceBox: CGRect { CGRect(x: modelPadX, y: modelPadY, width: modelWidth, height: modelHeight) }
    var modelExtent: CGRect { CGRect(x: 0, y: 0, width: modelWidth + 2 * modelPadX, height: modelHeight + 2 * modelPadY) }
    var restoreScaleX: CGFloat { CGFloat(sourceWidth) / CGFloat(modelWidth) }
    var restoreScaleY: CGFloat { CGFloat(sourceHeight) / CGFloat(modelHeight) }
    var featherX: CGFloat { min(3 * restoreScaleX, CGFloat(sourceWidth) / 2) }
    var featherY: CGFloat { min(3 * restoreScaleY, CGFloat(sourceHeight) / 2) }
}

private func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}

private func sourceBlendMask(box: CGRect, featherX: CGFloat, featherY: CGFloat, extent: CGRect) throws -> CIImage {
    func ramp(from a: CGPoint, to b: CGPoint) throws -> CIImage {
        guard let filter = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: a), "inputPoint1": CIVector(cgPoint: b),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white
        ]), let result = filter.outputImage else {
            throw ExpansionError(message: "Could not create the expansion seam mask.")
        }
        return result.cropped(to: extent)
    }
    let sides = try [
        ramp(from: CGPoint(x: box.minX, y: box.midY), to: CGPoint(x: box.minX + featherX, y: box.midY)),
        ramp(from: CGPoint(x: box.maxX, y: box.midY), to: CGPoint(x: box.maxX - featherX, y: box.midY)),
        ramp(from: CGPoint(x: box.midX, y: box.minY), to: CGPoint(x: box.midX, y: box.minY + featherY)),
        ramp(from: CGPoint(x: box.midX, y: box.maxY), to: CGPoint(x: box.midX, y: box.maxY - featherY))
    ]
    return sides.dropFirst().reduce(sides[0]) { mask, side in
        mask.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: side])
    }.cropped(to: extent)
}

private func expandPhoto(input: URL, output: URL, percent: Int) throws {
    let fileManager = FileManager.default
    guard fileManager.isReadableFile(atPath: input.path) else {
        throw ExpansionError(message: "The input photo is missing or unreadable.")
    }
    for name in ["expanded.png", "expansion.json"] {
        let destination = output.appendingPathComponent(name)
        guard destination.resolvingSymlinksInPath() != input.resolvingSymlinksInPath(),
              !fileManager.fileExists(atPath: destination.path) else {
            throw ExpansionError(message: "The output already contains \(name); refusing to overwrite an existing file.")
        }
    }
    let start = ProcessInfo.processInfo.systemUptime
    let models = try CleanupModels.installed()
    print("EXPANSION Decoding and color-managing the original photo")
    let (buffer, colorMetadata) = try loadColorManagedReframeImage(from: input)
    let geometry = try ExpansionGeometry(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), percent: percent)
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw ExpansionError(message: "The sRGB color profile is unavailable.")
    }
    let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .workingFormat: CIFormat.RGBAh])
    let source = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: srgb])
    let scaleY = CGFloat(geometry.modelHeight) / CGFloat(geometry.sourceHeight)
    let scaleX = CGFloat(geometry.modelWidth) / CGFloat(geometry.sourceWidth)
    let modelPhoto = source.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY
    ]).cropped(to: CGRect(x: 0, y: 0, width: geometry.modelWidth, height: geometry.modelHeight))
    let placedModelPhoto = modelPhoto.transformed(by: CGAffineTransform(translationX: CGFloat(geometry.modelPadX), y: CGFloat(geometry.modelPadY)))
    let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: geometry.modelExtent)
    let canvas = placedModelPhoto.composited(over: gray).cropped(to: geometry.modelExtent)
    let white = CIImage(color: .white).cropped(to: geometry.modelExtent)
    let black = CIImage(color: .black).cropped(to: geometry.modelSourceBox)
    let borderMask = black.composited(over: white).cropped(to: geometry.modelExtent)

    print("EXPANSION Loading installed Apple Fast Clean Up models")
    let loadStart = ProcessInfo.processInfo.systemUptime
    let pipeline = try models.load()
    let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
    print("EXPANSION Generating \(percent)% per edge with Apple Fast Clean Up")
    let inferenceStart = ProcessInfo.processInfo.systemUptime
    let generated = try pipeline.renderTile(context: context, inputImage: canvas, maskImage: borderMask,
                                            exclusionMaskImage: nil, orientation: .up, shouldDilateMask: false)
    // Materialize once: retaining a lazy CIImage would allow later writes to
    // repeat the expensive model graph after intermediate cache eviction.
    guard let raster = context.createCGImage(generated, from: geometry.modelExtent,
                                             format: .RGBAh, colorSpace: srgb, deferred: false) else {
        throw ExpansionError(message: "Apple Fast Clean Up did not produce an expanded image.")
    }
    let inferenceSeconds = ProcessInfo.processInfo.systemUptime - inferenceStart
    let generatedRaster = CIImage(cgImage: raster, options: [.colorSpace: srgb])
    let fullGenerated = generatedRaster.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: geometry.restoreScaleY,
        kCIInputAspectRatioKey: geometry.restoreScaleX / geometry.restoreScaleY
    ]).transformed(by: CGAffineTransform(
        translationX: CGFloat(geometry.padX) - CGFloat(geometry.modelPadX) * geometry.restoreScaleX,
        y: CGFloat(geometry.padY) - CGFloat(geometry.modelPadY) * geometry.restoreScaleY
    )).cropped(to: geometry.outputExtent)
    let placedSource = source.transformed(by: CGAffineTransform(translationX: CGFloat(geometry.padX), y: CGFloat(geometry.padY)))
    let blendMask = try sourceBlendMask(box: geometry.sourceBox, featherX: geometry.featherX,
                                      featherY: geometry.featherY, extent: geometry.outputExtent)
    let restored = placedSource.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: fullGenerated, kCIInputMaskImageKey: blendMask
    ]).cropped(to: geometry.outputExtent)

    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    let staging = output.appendingPathComponent(".expansion-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: staging) }
    print("EXPANSION Restoring full-resolution source and saving sRGB output")
    try context.writePNGRepresentation(of: restored, to: staging.appendingPathComponent("expanded.png"), format: .RGBA8, colorSpace: srgb)
    let preserveInsetX = Int(ceil(geometry.featherX))
    let preserveInsetY = Int(ceil(geometry.featherY))
    let report: [String: Any] = [
        "schema": 1, "helper_protocol_version": expansionProtocolVersion,
        "status": "complete", "backend": expansionBackend, "identity": models.identity,
        "input": input.path, "percent_per_edge": percent,
        "source_size": [geometry.sourceWidth, geometry.sourceHeight],
        "output_size": [geometry.outputWidth, geometry.outputHeight],
        "original_box_top_left": [geometry.padX, geometry.padY, geometry.sourceWidth, geometry.sourceHeight],
        "original_box_bottom_left": [geometry.padX, geometry.padY, geometry.sourceWidth, geometry.sourceHeight],
        "preserved_box_top_left": [geometry.padX + preserveInsetX, geometry.padY + preserveInsetY,
                                   max(0, geometry.sourceWidth - 2 * preserveInsetX), max(0, geometry.sourceHeight - 2 * preserveInsetY)],
        "padding_lrtb": [geometry.padX, geometry.padX, geometry.padY, geometry.padY],
        "model_source_size": [geometry.modelWidth, geometry.modelHeight],
        "model_canvas_size": [Int(geometry.modelExtent.width), Int(geometry.modelExtent.height)],
        "model_padding_lrtb": [geometry.modelPadX, geometry.modelPadX, geometry.modelPadY, geometry.modelPadY],
        "feather_model_pixels": 3,
        "feather_source_pixels_xy": [Double(geometry.featherX), Double(geometry.featherY)],
        "preservation": "Full-resolution color-managed SDR sRGB source center; narrow inner seam blended with generated context",
        "output_color_space": "sRGB", "color_metadata": colorMetadata,
        "orientation_applied": true, "mask": "white new border; black source", "dilate_mask": false,
        "model_load_seconds": loadSeconds, "inference_and_materialization_seconds": inferenceSeconds,
        "total_seconds": ProcessInfo.processInfo.systemUptime - start
    ]
    try writeJSON(report, to: staging.appendingPathComponent("expansion.json"))
    let finalImage = output.appendingPathComponent("expanded.png")
    try fileManager.moveItem(at: staging.appendingPathComponent("expanded.png"), to: finalImage)
    do {
        // The manifest is the completion marker. Never leave a claimed success
        // when saving either member of the output pair failed.
        try fileManager.moveItem(at: staging.appendingPathComponent("expansion.json"), to: output.appendingPathComponent("expansion.json"))
    } catch {
        try? fileManager.removeItem(at: finalImage)
        throw error
    }
    print("EXPANSION SAVED", finalImage.path)
}

@main
private struct ExpandPhotoCommand {
    static func main() {
        setbuf(stdout, nil)
        signal(SIGALRM) { _ in
            let message: StaticString = "ERROR: Apple Fast Clean Up expansion timed out after 180 seconds.\n"
            _ = Darwin.write(STDERR_FILENO, message.utf8Start, message.utf8CodeUnitCount)
            _exit(124)
        }
        alarm(expansionTimeoutSeconds)
        defer { alarm(0) }
        do {
            let args = CommandLine.arguments
            if args.count == 2, args[1] == "--identity" {
                let data = try JSONSerialization.data(withJSONObject: CleanupModels.installed().identity, options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
                return
            }
            guard args.count == 4, let percent = Int(args[3]), (1...20).contains(percent) else {
                fputs("Usage: ExpandPhoto INPUT OUTPUT_DIR PERCENT_PER_EDGE (integer 1...20)\n       ExpandPhoto --identity\n", stderr)
                exit(2)
            }
            let input = URL(fileURLWithPath: args[1]).standardizedFileURL
            let output = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
            try expandPhoto(input: input, output: output, percent: percent)
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
