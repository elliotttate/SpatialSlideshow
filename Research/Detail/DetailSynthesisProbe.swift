import Foundation

/// Standalone entry point for the research-only border detail synthesizer.
@main
private struct DetailSynthesisProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: DetailSynthesisProbe JOB.json\n", stderr)
            exit(2)
        }
        do {
            try ExpansionDetailSynthesis.run(jobPath: CommandLine.arguments[1])
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
