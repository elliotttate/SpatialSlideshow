import Foundation
import CoreVideo
import AlchemistBase

final class Cancellation: Cancellable {
 var isCancelled = false
 func cancel() { isCancelled = true }
 func checkCancellation() throws { if isCancelled { throw NSError(domain: "Slideshow", code: 1) } }
}

// Use the installed, registered asset in place. Restore-image copies failed
// to load on the tested Mac; these registered paths succeed.
func installedModels() throws -> (joint: URL, fov: URL) {
 let root = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_SpatialPhotosRelive/purpose_auto")
 var joint: [URL] = [], fov: [URL] = []
 for asset in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where asset.pathExtension == "asset" {
  let contents = (try? FileManager.default.contentsOfDirectory(at: asset.appendingPathComponent(".AssetData"), includingPropertiesForKeys: nil)) ?? []
  let models = contents.filter { $0.pathExtension == "mlmodelc" }
  // macOS registers these predictors as separate assets. Require a unique
  // installed model of each kind instead of depending on directory order.
  joint += models.filter { $0.lastPathComponent.contains("joint_predictor") }
  fov += models.filter { $0.lastPathComponent.contains("fov_") }
 }
 guard joint.count == 1, fov.count == 1 else {
  let message = joint.isEmpty || fov.isEmpty ? "Photos Spatial Reframing assets are not installed. Open a spatial photo in Photos to download them." : "Multiple Photos Spatial Reframing model versions are installed. No unambiguous model pair is available."
  throw NSError(domain: "Slideshow", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
 }
 return (joint[0], fov[0])
}

@main
struct GenerateSceneCommand {
 static func main() {
 do {
 setbuf(stdout, nil)
 guard CommandLine.arguments.count == 3 else { print("Usage: GenerateScene photo output-directory"); exit(2) }
 let input = URL(fileURLWithPath: CommandLine.arguments[1])
 let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
 try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
 let models = try installedModels(), pipeline = ALCBasePipeline()
 try pipeline.createAndLoadJointPredictor(models.joint)
 try pipeline.createAndLoadFoVPredictor(models.fov)
 print("LOADED actual Photos joint and FOV models")
 let (image, colorMetadata) = try loadColorManagedReframeImage(from: input)
 print("COLOR", colorMetadata)
 let start = Date()
 let (buffers, auxiliary) = try pipeline.generateSplats(image, focalLengthPx: nil, canceller: Cancellation()) { print("PROGRESS", $0) }
 var manifest: [String: Any] = ["source": input.path, "width": CVPixelBufferGetWidth(image), "height": CVPixelBufferGetHeight(image), "focalLengthPx": auxiliary.outputFocalLengthPx, "unprojectionFocalLengthPx": [auxiliary.outputUnprojectionFocalLengthPx.x, auxiliary.outputUnprojectionFocalLengthPx.y], "seconds": Date().timeIntervalSince(start), "jointModel": models.joint.path, "fovModel": models.fov.path]
 manifest.merge(colorMetadata) { _, new in new }
 var entries: [String: Any] = [:]
 for (name, buffer) in [("positions",buffers.positions),("rotations",buffers.rotations),("scales",buffers.scales),("colors",buffers.colors),("alphas",buffers.alphas),("depths",buffers.depths)] {
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer), format = CVPixelBufferGetPixelFormatType(buffer)
  guard let pointer = CVPixelBufferGetBaseAddress(buffer) else { throw NSError(domain: "Slideshow", code: 3) }
  try Data(bytes: pointer, count: stride * height).write(to: output.appendingPathComponent(name + ".bin"))
  entries[name] = ["width": width, "height": height, "bytesPerRow": stride, "pixelFormat": format]
  print("BUFFER", name, width, height, stride, String(format: "%08x", format))
 }
 manifest["buffers"] = entries
 try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("scene.json"))
 print("SCENE SAVED", output.path)
 } catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
 }
}
