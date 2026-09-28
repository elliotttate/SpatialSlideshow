import Foundation
import Metal
import CoreImage
import QuartzCore

private final class FrameTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ duration: Double) { lock.lock(); values.append(duration); lock.unlock() }
    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "no GPU timing" }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return "GPU mean \(mean * 1000) ms, p95 \(sorted[min(sorted.count - 1, sorted.count * 95 / 100)] * 1000) ms, frames over16.7ms \(sorted.filter { $0 > 1 / 60.0 }.count)/\(sorted.count)"
    }
}

// Standalone opt-in integration test; use synthetic scenes or Trip fixtures only.
// Build with LiveGaussianRenderer.o and -import-objc-header LiveGaussianRenderer.h.
@main
struct LiveGaussianRendererSmokeTest {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("Usage: LiveGaussianRendererSmokeTest scene-one scene-two output-directory")
        }
        guard LiveGaussianScene.isAvailable(), let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(), let linear = CGColorSpace(name: CGColorSpace.linearSRGB),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { fatalError("Metal / Apple renderer unavailable") }
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let started = CACurrentMediaTime()
        let scenes = try CommandLine.arguments[1...2].map { try LiveGaussianScene(url: URL(fileURLWithPath: $0), device: device) }
        print("Loaded two scenes in \(CACurrentMediaTime() - started)s, input bytes \(scenes.map(\.byteCost))")
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: linear])
        let width = Int(ProcessInfo.processInfo.environment["SPATIAL_BENCHMARK_WIDTH"] ?? "1920") ?? 1920
        let height = Int(ProcessInfo.processInfo.environment["SPATIAL_BENCHMARK_HEIGHT"] ?? "1080") ?? 1080
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let targets = (0..<2).map { _ in device.makeTexture(descriptor: descriptor)! }
        let slots = DispatchSemaphore(value: 2)
        for twoScenes in [false, true] {
            let begin = CACurrentMediaTime()
            let count = 180
            let timings = FrameTimings()
            for frame in 0..<count {
                slots.wait()
                try autoreleasepool {
                    guard let command = queue.makeCommandBuffer() else { fatalError("No command buffer") }
                    command.label = "Live splat integration frame \(frame)"
                    let progress = Float(frame) / Float(count - 1)
                    var image = try scenes[0].encodeFrame(with: command, width: UInt(width), height: UInt(height), fit: true,
                                                        pattern: 0, progress: progress, strength: 2.5, zoomOut: 0)
                    if twoScenes {
                        let incoming = try scenes[1].encodeFrame(with: command, width: UInt(width), height: UInt(height), fit: true,
                                                                pattern: 3, progress: progress, strength: 2.5, zoomOut: 0)
                        image = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: incoming, kCIInputTimeKey: progress])
                    }
                    context.render(image, to: targets[frame % 2], commandBuffer: command,
                                   bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: sRGB)
                    command.addCompletedHandler { completed in
                        if completed.status != .completed { fatalError("GPU command failed: \(String(describing: completed.error))") }
                        timings.add(completed.gpuEndTime - completed.gpuStartTime)
                        slots.signal()
                    }
                    // encodeFrame must leave commitment in the compositor's control.
                    precondition(command.status == .notEnqueued)
                    command.commit()
                    if frame == 0 || frame == count / 2 || frame == count - 1 {
                        command.waitUntilCompleted()
                        try context.writePNGRepresentation(of: image, to: output.appendingPathComponent("\(twoScenes ? "fade" : "single")-\(frame).png"),
                                                           format: .RGBA8, colorSpace: sRGB)
                    }
                }
            }
            slots.wait(); slots.wait()
            let elapsed = CACurrentMediaTime() - begin
            print("\(twoScenes ? "Two-scene fade" : "Single scene"): \(Double(count) / elapsed) frames/s at \(width)x\(height), including PNG snapshots")
            print(timings.report())
            slots.signal(); slots.signal()
        }
        // Validate resizing/framing and reject a non-finite UI value cleanly.
        let command = queue.makeCommandBuffer()!
        _ = try scenes[0].encodeFrame(with: command, width: 1280, height: 720, fit: false, pattern: 5, progress: 0.5, strength: 4, zoomOut: 20)
        command.commit(); command.waitUntilCompleted()
        do {
            _ = try scenes[0].encodeFrame(with: queue.makeCommandBuffer()!, width: 1280, height: 720, fit: true, pattern: 0,
                                        progress: .nan, strength: 1, zoomOut: 0)
            fatalError("Non-finite progress was accepted")
        } catch { print("Invalid frame settings rejected: \(error.localizedDescription)") }
        print("PASS: live Gaussian frames, crossfades, two commands in flight, resize, and invalid input handling")
    }
}
