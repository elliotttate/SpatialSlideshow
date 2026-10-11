import Foundation
import CoreImage
import CoreML
import CoreVideo
import ImageIO
import PhotosGenerativeServices

// Measures how the pixels under the Clean Up mask steer a generated border.
// Usage: FillPriorProbe TRIP_EXPORT OUTPUT_DIR PERCENT FILL [OVERLAP]
//   FILL: gray | black | white | clamp | mirror     OVERLAP: model pixels regenerated inside the photo
// Writes the model canvas and the pipeline result as PNGs and prints the mean
// color step across each join. Use only a user-supplied Trip export.

struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

func modelRoot() throws -> URL {
    let assets = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_MagicCleanup/purpose_auto")
    let candidates = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "asset" }.map { $0.appendingPathComponent(".AssetData") }
        .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("inpainting.mlmodelc").path)
            && FileManager.default.fileExists(atPath: $0.appendingPathComponent("refinement.mlmodelc").path) }
    guard candidates.count == 1 else { throw Failure(message: "Expected exactly one installed Fast Clean Up model pair, found \(candidates.count).") }
    return candidates[0]
}

func loadPipeline() throws -> InpaintGANPipeline {
    let root = try modelRoot()
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    configuration.setValue(true, forKey: "usePrecompiledE5Bundle")
    var pipeline = InpaintGANPipeline(cleanupModel: try MLModel(contentsOf: root.appendingPathComponent("inpainting.mlmodelc"), configuration: configuration))
    pipeline.refinementModel = try MLModel(contentsOf: root.appendingPathComponent("refinement.mlmodelc"), configuration: configuration)
    return pipeline
}

func decode(_ url: URL) throws -> CIImage {
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: false, .toneMapHDRtoSDR: true]) else {
        throw Failure(message: "Could not decode the photo.")
    }
    return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
}

func rgb(_ image: CIImage, _ extent: CGRect, _ context: CIContext, _ srgb: CGColorSpace) -> [Float] {
    let w = Int(extent.width), h = Int(extent.height)
    var data = [Float](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: srgb) }
    return data
}

let args = CommandLine.arguments
guard args.count >= 5, let percent = Int(args[3]), (1...20).contains(percent) else {
    FileHandle.standardError.write(Data("Usage: FillPriorProbe TRIP_EXPORT OUTPUT_DIR PERCENT FILL [OVERLAP]\n".utf8)); exit(2)
}
do {
    let fill = args[4], overlap = args.count > 5 ? Int(args[5]) ?? 0 : 0
    let out = URL(fileURLWithPath: args[2], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb, .workingFormat: CIFormat.RGBAh])
    let source = try decode(URL(fileURLWithPath: args[1]))
    let W = Int(source.extent.width), H = Int(source.extent.height)
    let scale = min(1, 1024 / Double(max(W, H)))
    let mw = Int((Double(W) * scale).rounded()), mh = Int((Double(H) * scale).rounded())
    let padX = max(1, Int(ceil(Double(mw) * Double(percent) / 100))), padY = max(1, Int(ceil(Double(mh) * Double(percent) / 100)))
    let extent = CGRect(x: 0, y: 0, width: mw + 2 * padX, height: mh + 2 * padY)
    let box = CGRect(x: padX, y: padY, width: mw, height: mh)
    let small = source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(mh) / Double(H), kCIInputAspectRatioKey: (Double(mw) / Double(W)) / (Double(mh) / Double(H))]).cropped(to: CGRect(x: 0, y: 0, width: mw, height: mh))
    let placed = small.transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
    let background: CIImage
    switch fill {
    case "gray": background = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
    case "black": background = CIImage(color: .black).cropped(to: extent)
    case "white": background = CIImage(color: .white).cropped(to: extent)
    case "clamp": background = placed.clampedToExtent().cropped(to: extent)
    case "mirror":
        var image = placed
        for transform in [CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -2 * box.minX, y: 0),
                          CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -2 * box.maxX, y: 0),
                          CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -2 * box.minY),
                          CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -2 * box.maxY)] {
            image = image.composited(over: placed.transformed(by: transform))
        }
        background = image.clampedToExtent().cropped(to: extent)
    default: throw Failure(message: "FILL must be gray, black, white, clamp or mirror.")
    }
    let canvas = placed.composited(over: background).cropped(to: extent)
    let mask = CIImage(color: .black).cropped(to: box.insetBy(dx: CGFloat(overlap), dy: CGFloat(overlap)))
        .composited(over: CIImage(color: .white).cropped(to: extent)).cropped(to: extent)
    let pipeline = try loadPipeline()
    let started = Date()
    let generated = try pipeline.renderTile(context: context, inputImage: canvas, maskImage: mask, exclusionMaskImage: nil, orientation: .up, shouldDilateMask: false)
    guard let raster = context.createCGImage(generated, from: extent, format: .RGBAh, colorSpace: srgb, deferred: false) else { throw Failure(message: "No result.") }
    print("canvas \(Int(extent.width))x\(Int(extent.height)) fill \(fill) overlap \(overlap) seconds \(String(format: "%.2f", Date().timeIntervalSince(started)))")
    let result = CIImage(cgImage: raster, options: [.colorSpace: srgb])
    let name = "p\(percent)-\(fill)-o\(overlap)"
    try context.writePNGRepresentation(of: canvas, to: out.appendingPathComponent(name + "-input.png"), format: .RGBA8, colorSpace: srgb)
    try context.writePNGRepresentation(of: result, to: out.appendingPathComponent(name + "-output.png"), format: .RGBA8, colorSpace: srgb)
    // Mean color inside versus outside each join over a 4-pixel band (bitmap rows are top-down).
    let pixels = rgb(result, extent, context, srgb)
    let w = Int(extent.width), h = Int(extent.height), band = 4
    func mean(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> [Float] {
        var sum: [Float] = [0, 0, 0]; var n: Float = 0
        for y in y0..<y1 { for x in x0..<x1 { let i = (y * w + x) * 4; sum[0] += pixels[i]; sum[1] += pixels[i + 1]; sum[2] += pixels[i + 2]; n += 1 } }
        return sum.map { $0 / n * 255 }
    }
    let x0 = padX, x1 = padX + mw, y0 = padY, y1 = padY + mh
    let sides = [("left", mean(x0, x0 + band, y0, y1), mean(x0 - band, x0, y0, y1)), ("right", mean(x1 - band, x1, y0, y1), mean(x1, x1 + band, y0, y1)),
                 ("top", mean(x0, x1, y0, y0 + band), mean(x0, x1, y0 - band, y0)), ("bottom", mean(x0, x1, y1 - band, y1), mean(x0, x1, y1, y1 + band))]
    for (side, inside, outside) in sides {
        print(String(format: "%-6@ inside (%.1f %.1f %.1f) outside (%.1f %.1f %.1f) step (%.1f %.1f %.1f)", side, inside[0], inside[1], inside[2],
                     outside[0], outside[1], outside[2], inside[0] - outside[0], inside[1] - outside[1], inside[2] - outside[2]))
    }
    _ = h
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8)); exit(1)
}
