import Foundation
import CoreImage
import CoreVideo
import Darwin

/// Shared photo decoder for the optional local outpainting backend. The original
/// and inference copy use the same SDR sRGB conversion as the Reframe model.
@main
private struct PrepareExpansionPhoto {
    static func main() {
        do {
            let args = CommandLine.arguments
            if args.count == 7, args[1] == "--restore" {
                try restoreOriginal(args)
                return
            }
            guard args.count == 3 || args.count == 4,
                  let edge = Int(args.count == 4 ? args[3] : "768"), (64...768).contains(edge) else {
                throw NSError(domain: "PhotoExpansion", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Usage: PrepareExpansionPhoto INPUT OUTPUT_DIRECTORY [MODEL_LONG_EDGE:64...768]"])
            }
            let input = URL(fileURLWithPath: args[1])
            let output = URL(fileURLWithPath: args[2], isDirectory: true)
            let (buffer, metadata) = try loadColorManagedReframeImage(from: input)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            guard width > 0, height > 0, width <= 100_000, height <= 100_000,
                  let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
                throw NSError(domain: "PhotoExpansion", code: 2, userInfo: [NSLocalizedDescriptionKey: "The photo has unsupported dimensions or color profile."])
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh])
            let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: srgb])
            try context.writePNGRepresentation(of: image, to: output.appendingPathComponent("original-srgb.png"), format: .RGBA8, colorSpace: srgb)
            let scale = min(1, Double(edge) / Double(max(width, height)))
            let smallWidth = max(1, Int((Double(width) * scale).rounded()))
            let smallHeight = max(1, Int((Double(height) * scale).rounded()))
            let sx = Double(smallWidth) / Double(width), sy = Double(smallHeight) / Double(height)
            let small = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy
            ]).cropped(to: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
            try context.writePNGRepresentation(of: small, to: output.appendingPathComponent("model-input.png"), format: .RGBA8, colorSpace: srgb)
            var report = metadata
            report["source_size"] = [width, height]
            report["model_source_size"] = [smallWidth, smallHeight]
            report["orientation_applied"] = true
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("source.json"), options: .atomic)
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func restoreOriginal(_ args: [String]) throws {
        guard let x = Int(args[5]), let y = Int(args[6]), x >= 0, y >= 0,
              let original = CIImage(contentsOf: URL(fileURLWithPath: args[2])),
              let generated = CIImage(contentsOf: URL(fileURLWithPath: args[3])),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              Int(generated.extent.width) == Int(original.extent.width) + 2*x,
              Int(generated.extent.height) == Int(original.extent.height) + 2*y else {
            throw NSError(domain: "PhotoExpansion", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Native Extend returned unexpected image dimensions; the original photo was not composited."])
        }
        let destination = URL(fileURLWithPath: args[4])
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "PhotoExpansion", code: 5, userInfo: [NSLocalizedDescriptionKey: "Expansion output already exists."])
        }
        let image = original.transformed(by: CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y)))
            .composited(over: generated).cropped(to: generated.extent)
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh])
        try context.writePNGRepresentation(of: image, to: destination, format: .RGBA8, colorSpace: srgb)
    }
}
