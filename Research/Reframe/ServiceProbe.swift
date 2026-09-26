import Foundation
import CoreImage
import Metal
import AlchemistService
@main struct Probe {
 static func main() async {
  guard dlopen("/System/Library/PrivateFrameworks/AlchemistService.framework/AlchemistService",RTLD_NOW|RTLD_GLOBAL) != nil else { fatalError("dlopen") }
  do {
   let config=ALCConfiguration(for:.reframing)
   let service=try ALCService(mtlDevice:MTLCreateSystemDefaultDevice()!, configuration:config,eventHandler: { event,output in print("PROGRESS",event.progressValue);fflush(stdout); return true })
   print("SERVICE READY");fflush(stdout)
   let image=CIImage(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))!
   let force=CommandLine.arguments.contains("--in-process")
   let result=try await service.generateRequested(from:image,with:config,options:[.requestGaussians:true,.forceInProcess:force])
   print("RESULT",result.mxi as Any,result.gaussians as Any);fflush(stdout)
   if let scene=result.mxi { print("SCENE",scene.vertexCount,scene.triangleCount,scene.attributes as Any); try scene.write(to:URL(fileURLWithPath:CommandLine.arguments.count > 2 && !CommandLine.arguments[2].hasPrefix("--") ? CommandLine.arguments[2] : "sample.mxi")) }
  } catch { print("ERROR",error);fflush(stdout); exit(1) }
 }
}
