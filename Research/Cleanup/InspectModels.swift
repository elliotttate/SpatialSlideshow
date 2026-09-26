import Foundation
import CoreML
import Darwin

alarm(120)
setbuf(stdout, nil)
let root = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_MagicCleanup/purpose_auto")
do {
    let assets = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    for asset in assets.sorted(by: { $0.path < $1.path }) where asset.pathExtension == "asset" {
        for name in ["inpainting", "refinement"] {
            let path = asset.appendingPathComponent(".AssetData/\(name).mlmodelc")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            if configuration.responds(to: NSSelectorFromString("setUsePrecompiledE5Bundle:")) {
                configuration.setValue(true, forKey: "usePrecompiledE5Bundle")
                print("CONFIG usePrecompiledE5Bundle", configuration.value(forKey: "usePrecompiledE5Bundle") ?? "nil")
            }
            let start = Date()
            print("LOAD", path.path)
            let model = try MLModel(contentsOf: path, configuration: configuration)
            print("LOADED", name, Date().timeIntervalSince(start))
            print("INPUTS", model.modelDescription.inputDescriptionsByName)
            print("OUTPUTS", model.modelDescription.outputDescriptionsByName)
            print("METADATA", model.modelDescription.metadata)
        }
    }
} catch { print("ERROR", error); exit(1) }
