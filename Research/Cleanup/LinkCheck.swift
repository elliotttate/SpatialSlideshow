import Foundation
import CoreImage
import CoreML
import ImageIO
import PhotosGenerativeServices

// This is compiled to check all required call symbols; it is never invoked.
@inline(never)
func checkedSignature(_ model: MLModel, _ refinement: MLModel?, _ context: CIContext,
                      _ input: CIImage, _ mask: CIImage) throws -> CIImage {
    var pipeline = InpaintGANPipeline(cleanupModel: model)
    pipeline.refinementModel = refinement
    return try pipeline.renderTile(context: context, inputImage: input,
                                   maskImage: mask, exclusionMaskImage: nil,
                                   orientation: .up, shouldDilateMask: false)
}

print("InpaintGANPipeline linked. Size=\(MemoryLayout<InpaintGANPipeline>.size) stride=\(MemoryLayout<InpaintGANPipeline>.stride) alignment=\(MemoryLayout<InpaintGANPipeline>.alignment). No model loaded; no inference called.")
