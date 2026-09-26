import Foundation
import AlchemistBase
do {
 guard dlopen("/System/Library/PrivateFrameworks/AlchemistBase.framework/AlchemistBase",RTLD_NOW|RTLD_GLOBAL) != nil else { fatalError("dlopen") }
 let p = ALCBasePipeline()
 do {
  let url = URL(fileURLWithPath: CommandLine.arguments[1])
  if CommandLine.arguments.contains("--joint") {
   try p.createAndLoadJointPredictor(url)
   print("Loaded joint", p.isJointPredictorLoaded)
  } else {
   try p.createAndLoadFoVPredictor(url)
   print("Loaded FOV", p.isFoVPredictorLoaded)
  }
 } catch { print("Error:",error); exit(1) }
}
