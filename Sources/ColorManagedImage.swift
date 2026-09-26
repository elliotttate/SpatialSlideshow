import Foundation
import CoreImage
import CoreVideo

/// Reframe's RGB input must have one defined encoding. Preserve the embedded
/// profile while decoding, tone-map HDR for SDR playback, then convert pixels
/// (not just their labels) into sRGB before the model sees them.
func loadColorManagedReframeImage(from url: URL) throws -> (CVPixelBuffer, [String: Any]) {
    guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: false]),
          let mapped = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: false, .toneMapHDRtoSDR: true]),
          let srgb = CGColorSpace(name: CGColorSpace.sRGB),
          let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
        throw NSError(domain: "Slideshow", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not decode this photo's color profile."])
    }
    let extent = mapped.extent.integral
    let width = Int(extent.width), height = Int(extent.height)
    guard width > 0, height > 0 else {
        throw NSError(domain: "Slideshow", code: 4, userInfo: [NSLocalizedDescriptionKey: "The photo has invalid dimensions."])
    }
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else {
        throw NSError(domain: "Slideshow", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not allocate the color-managed photo."])
    }
    let image = mapped.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    let context = CIContext(options: [.workingColorSpace: working, .workingFormat: CIFormat.RGBAh])
    context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: srgb)
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, srgb, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    let metadata: [String: Any] = [
        "colorPipelineVersion": 1,
        "sourceColorSpace": source.colorSpace?.name as String? ?? "untagged",
        "sourceHeadroom": Double(source.contentHeadroom),
        "modelInputColorSpace": "sRGB",
        "sceneColorSpace": "linear-sRGB",
        "hdrToneMapping": "CoreImage toneMapHDRtoSDR"
    ]
    return (buffer, metadata)
}
