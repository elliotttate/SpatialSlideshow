import Foundation

@main
enum ExpansionPipelineTest {
    static func main() throws {
        let args = CommandLine.arguments
        let source = PhotoSource.file(URL(fileURLWithPath: args[1]))
        let tools = URL(fileURLWithPath: args[2])
        let root = URL(fileURLWithPath: args[3])
        let expansion = try PhotoExpansionConfiguration.resolve(enabled: true, percent: 5, tools: tools)
        let session = RenderSession()
        var phases: [String] = []
        let expanded = try session.clip(source, seconds: 6, motion: 1, longEdge: 1920, motionPattern: 2,
                                       version: .current, root: root, tools: tools, expansion: expansion) {
            phases.append($0); print($0)
        }
        if args.last == "restart" {
            precondition(phases == ["Ready from cache"], "Another launch must reuse the expanded clip")
            print("PASS expanded clip reused in separate process")
            return
        }
        let repeated = try session.clip(source, seconds: 6, motion: 1, longEdge: 1920, motionPattern: 2,
                                       version: .current, root: root, tools: tools, expansion: expansion)
        precondition(repeated == expanded)
        precondition(session.cachedClip(source, seconds: 6, motion: 1, longEdge: 1920, motionPattern: 2,
                                        version: .current, root: root,
                                        expansion: PhotoExpansionConfiguration(percent: 10, modelFingerprint: expansion.modelFingerprint)) == nil)
        let plain = try session.clip(source, seconds: 6, motion: 1, longEdge: 1920, motionPattern: 2,
                                    version: .current, root: root, tools: tools)
        precondition(plain != expanded)
        let child = Process(); child.executableURL = URL(fileURLWithPath: args[0])
        child.arguments = Array(args.dropFirst()) + ["restart"]
        try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
        let scratch = root.appendingPathComponent("Work")
        let remainingScratch = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        precondition(remainingScratch.isEmpty)
        let report: [String: Any] = ["status": "passed", "source": args[1], "album": "Trip",
            "percent_per_edge": expansion.percent, "expanded_clip": expanded.path, "plain_clip": plain.path,
            "phases": phases, "cache_survives_restart": true, "amount_isolates_cache": true,
            "temporary_expansion_and_scene_files_removed": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("pipeline-test.json"))
        print("PASS real Apple expansion → Reframe → movie → persistent cache")
    }
}
