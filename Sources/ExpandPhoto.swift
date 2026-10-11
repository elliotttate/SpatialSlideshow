import Foundation
import CoreImage
import CoreML
import CoreVideo
import CryptoKit
import PhotosGenerativeServices
import Darwin

private let expansionProtocolVersion = 2
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
        let names = ["inpainting.mlmodelc", "refinement.mlmodelc"]
        let root = try AppleModelLocations.cleanupRoot()
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
            "compositor_version": expansionCompositorVersion,
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

/// Seam settings at model resolution (source long edge 1024). The GAN repaints
/// a thin band inside the photograph so its texture continues across the join;
/// detail then hands back to the full-resolution original over `inset` pixels
/// while lighting differences spread over `outerReach` pixels of new border.
private enum SeamSettings {
    static let maskOverlap = 12
    static let inset = 16
    static let outerReach = 64
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
    let overlap: Int
    let inset: Int

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
        // Tiny inputs keep a protected interior; the seam band shrinks instead.
        let limit = (min(modelWidth, modelHeight) - 1) / 4
        inset = max(0, min(SeamSettings.inset, limit))
        overlap = max(0, min(SeamSettings.maskOverlap, inset))
    }

    var outputWidth: Int { sourceWidth + 2 * padX }
    var outputHeight: Int { sourceHeight + 2 * padY }
    var sourceBox: CGRect { CGRect(x: padX, y: padY, width: sourceWidth, height: sourceHeight) }
    var outputExtent: CGRect { CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight) }
    var modelSourceBox: CGRect { CGRect(x: modelPadX, y: modelPadY, width: modelWidth, height: modelHeight) }
    var modelExtent: CGRect { CGRect(x: 0, y: 0, width: modelWidth + 2 * modelPadX, height: modelHeight + 2 * modelPadY) }
    var restoreScaleX: CGFloat { CGFloat(sourceWidth) / CGFloat(modelWidth) }
    var restoreScaleY: CGFloat { CGFloat(sourceHeight) / CGFloat(modelHeight) }
    /// Full-resolution width of the band where model-resolution seam context
    /// hands back to exact source pixels. Zero for inputs too small to band.
    var featherX: CGFloat { min(CGFloat(inset) * restoreScaleX, CGFloat(sourceWidth) / 2) }
    var featherY: CGFloat { min(CGFloat(inset) * restoreScaleY, CGFloat(sourceHeight) / 2) }
}

private func writeJSON(_ value: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}

/// Smoothstep restore mask: 1 inside the photograph beyond its feather band,
/// easing to 0 at the photograph's edge, 0 across the whole generated border.
private func sourceRestoreMask(box: CGRect, featherX: CGFloat, featherY: CGFloat, extent: CGRect) throws -> CIImage {
    guard featherX > 0, featherY > 0 else {
        return CIImage(color: .white).cropped(to: box).composited(over: CIImage(color: .black).cropped(to: extent)).cropped(to: extent)
    }
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
    let linear = sides.dropFirst().reduce(sides[0]) { mask, side in
        mask.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: side])
    }
    // Zero slope at both ends of the band hides the join without a visible stripe.
    let ease = CIVector(x: 0, y: 0, z: 3, w: -2)
    return linear.applyingFilter("CIColorPolynomial", parameters: [
        "inputRedCoefficients": ease, "inputGreenCoefficients": ease, "inputBlueCoefficients": ease,
        "inputAlphaCoefficients": CIVector(x: 1, y: 0, z: 0, w: 0)
    ]).cropped(to: extent)
}

private func readFloats(_ image: CIImage, extent: CGRect, context: CIContext, colorSpace: CGColorSpace) -> FloatRGBImage {
    let width = Int(extent.width), height = Int(extent.height)
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { raw in
        context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: colorSpace)
    }
    var rgb = [Float](repeating: 0, count: width * height * 3)
    for i in 0..<(width * height) { rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2] }
    return FloatRGBImage(width: width, height: height, data: rgb)
}

private func makeImage(_ image: FloatRGBImage, colorSpace: CGColorSpace) -> CIImage {
    var rgba = [Float](repeating: 1, count: image.width * image.height * 4)
    for i in 0..<(image.width * image.height) {
        rgba[4 * i] = image.data[3 * i]; rgba[4 * i + 1] = image.data[3 * i + 1]; rgba[4 * i + 2] = image.data[3 * i + 2]
    }
    let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    return CIImage(bitmapData: data, bytesPerRow: image.width * 16, size: CGSize(width: image.width, height: image.height),
                   format: .RGBAf, colorSpace: colorSpace)
}

private func readBytes(_ image: CIImage, extent: CGRect, context: CIContext, colorSpace: CGColorSpace) -> [UInt8] {
    let width = Int(extent.width), height = Int(extent.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
        context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: colorSpace)
    }
    return bytes
}

/// Compare the saved file's protected interior with the decoded source. The
/// manifest claims exact pixels there, so a mismatch is an error, not a note.
private func verifyPreservedInterior(saved: URL, source: CIImage, geometry: ExpansionGeometry, insetX: Int, insetY: Int,
                                     context: CIContext, colorSpace: CGColorSpace) throws -> Int {
    let width = geometry.sourceWidth - 2 * insetX, height = geometry.sourceHeight - 2 * insetY
    guard width > 0, height > 0 else { return 0 }
    guard let decoded = CIImage(contentsOf: saved, options: [.applyOrientationProperty: true]) else {
        throw ExpansionError(message: "The saved expanded image could not be decoded for verification.")
    }
    // Compare in horizontal strips so a panorama does not need two full-size
    // 8-bit copies at once.
    var worst = 0
    let stripRows = max(1, min(height, 4_000_000 / max(width, 1)))
    var row = 0
    while row < height {
        let rows = min(stripRows, height - row)
        let savedBox = CGRect(x: geometry.padX + insetX, y: geometry.padY + insetY + row, width: width, height: rows)
        let sourceBox = CGRect(x: insetX, y: insetY + row, width: width, height: rows)
        let expected = readBytes(source, extent: sourceBox, context: context, colorSpace: colorSpace)
        let actual = readBytes(decoded, extent: savedBox, context: context, colorSpace: colorSpace)
        for i in stride(from: 0, to: expected.count, by: 4) {
            for c in 0..<3 { worst = max(worst, abs(Int(expected[i + c]) - Int(actual[i + c]))) }
        }
        row += rows
    }
    return worst
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
    let modelRect = CGRect(x: 0, y: 0, width: geometry.modelWidth, height: geometry.modelHeight)
    // Materialize the model-resolution source once so the canvas the model sees
    // and the pixels the compositor measures are the same raster.
    guard let smallRaster = context.createCGImage(source.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY
    ]).cropped(to: modelRect), from: modelRect, format: .RGBAh, colorSpace: srgb, deferred: false) else {
        throw ExpansionError(message: "Could not prepare the model-resolution photo.")
    }
    let modelPhoto = CIImage(cgImage: smallRaster, options: [.colorSpace: srgb])
    let placedModelPhoto = modelPhoto.transformed(by: CGAffineTransform(translationX: CGFloat(geometry.modelPadX), y: CGFloat(geometry.modelPadY)))
    // The pipeline reads the pixels under its mask as a prior: a flat gray fill
    // pulled the generated border toward gray and darkened it, while replicated
    // edge pixels keep its color and lighting continuous with the photograph.
    let fill = placedModelPhoto.clampedToExtent().cropped(to: geometry.modelExtent)
    let canvas = placedModelPhoto.composited(over: fill).cropped(to: geometry.modelExtent)
    let white = CIImage(color: .white).cropped(to: geometry.modelExtent)
    let keep = geometry.modelSourceBox.insetBy(dx: CGFloat(geometry.overlap), dy: CGFloat(geometry.overlap))
    let borderMask = CIImage(color: .black).cropped(to: keep).composited(over: white).cropped(to: geometry.modelExtent)

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

    print("EXPANSION Matching border colors and blending the seam")
    let compositeStart = ProcessInfo.processInfo.systemUptime
    let generatedRaster = CIImage(cgImage: raster, options: [.colorSpace: srgb])
    let generatedPixels = readFloats(generatedRaster, extent: geometry.modelExtent, context: context, colorSpace: srgb)
    let sourcePixels = readFloats(modelPhoto, extent: modelRect, context: context, colorSpace: srgb)
    // Rows are top-down in these bitmaps, so the top padding is the model's top.
    let matched = try harmonizeBorder(generated: generatedPixels, source: sourcePixels,
                                      left: geometry.modelPadX, top: geometry.modelPadY, restoreInset: geometry.overlap)
    var seamReport: [String: Any]? = nil
    var modelCanvas = matched.image
    if geometry.inset > 0 {
        let blended = try blendOverlap(generated: matched.image, source: sourcePixels, left: geometry.modelPadX,
                                       top: geometry.modelPadY, inset: geometry.inset, outerReach: SeamSettings.outerReach)
        modelCanvas = blended.image
        seamReport = blended.report
    }
    let compositeSeconds = ProcessInfo.processInfo.systemUptime - compositeStart

    let fullGenerated = makeImage(modelCanvas, colorSpace: srgb).applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: geometry.restoreScaleY,
        kCIInputAspectRatioKey: geometry.restoreScaleX / geometry.restoreScaleY
    ]).transformed(by: CGAffineTransform(
        translationX: CGFloat(geometry.padX) - CGFloat(geometry.modelPadX) * geometry.restoreScaleX,
        y: CGFloat(geometry.padY) - CGFloat(geometry.modelPadY) * geometry.restoreScaleY
    )).cropped(to: geometry.outputExtent)
    let placedSource = source.transformed(by: CGAffineTransform(translationX: CGFloat(geometry.padX), y: CGFloat(geometry.padY)))
    let restoreMask = try sourceRestoreMask(box: geometry.sourceBox, featherX: geometry.featherX,
                                            featherY: geometry.featherY, extent: geometry.outputExtent)
    let restored = placedSource.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: fullGenerated, kCIInputMaskImageKey: restoreMask
    ]).cropped(to: geometry.outputExtent)

    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
    let staging = output.appendingPathComponent(".expansion-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: staging) }
    print("EXPANSION Restoring full-resolution source and saving sRGB output")
    let stagedImage = staging.appendingPathComponent("expanded.png")
    try context.writePNGRepresentation(of: restored, to: stagedImage, format: .RGBA8, colorSpace: srgb)
    let preserveInsetX = Int(ceil(geometry.featherX))
    let preserveInsetY = Int(ceil(geometry.featherY))
    let interiorError = try verifyPreservedInterior(saved: stagedImage, source: source, geometry: geometry, insetX: preserveInsetX,
                                                    insetY: preserveInsetY, context: context, colorSpace: srgb)
    guard interiorError == 0 else {
        throw ExpansionError(message: "Original-pixel preservation check failed (maximum error \(interiorError)); the expansion was not saved.")
    }
    var report: [String: Any] = [
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
        "mask_fill": "edge-replicated source",
        "generated_overlap_model_pixels": geometry.overlap,
        "feather_model_pixels": geometry.inset,
        "feather_source_pixels_xy": [Double(geometry.featherX), Double(geometry.featherY)],
        "seam_blend": geometry.inset > 0 ? "multiband-generated-overlap" : "source-restore",
        "border_color_match": matched.report,
        "preservation": "Pixel-exact full-resolution color-managed SDR sRGB source interior; narrow inner band blended into color-matched generated overlap",
        "preserved_interior_max_rgb_error": interiorError,
        "output_color_space": "sRGB", "color_metadata": colorMetadata,
        "orientation_applied": true, "mask": "white new border and overlap; black protected source", "dilate_mask": false,
        "model_load_seconds": loadSeconds, "inference_and_materialization_seconds": inferenceSeconds,
        "seam_composite_seconds": compositeSeconds,
        "total_seconds": ProcessInfo.processInfo.systemUptime - start
    ]
    if let seamReport { report["multiband_seam"] = seamReport }
    try writeJSON(report, to: staging.appendingPathComponent("expansion.json"))
    let finalImage = output.appendingPathComponent("expanded.png")
    try fileManager.moveItem(at: stagedImage, to: finalImage)
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
