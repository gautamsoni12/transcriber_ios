#if DEBUG
import Foundation
import OSLog

/// Debug-only harness for exercising an engine without recording anything.
///
/// The simulator can't feed the microphone, so this runs a bundled speech sample
/// through a chosen engine and prints the transcript and metrics:
///
///     xcrun simctl launch <device> com.expandlabs.transcriber --selftest whisper
///
/// Bundled sample text:
/// "Let's ship the transcriber demo on Friday. I still need to test the compare
///  view and write the deployment notes."
enum SelfTest {
    static let expected = """
        Let's ship the transcriber demo on Friday. I still need to test the \
        compare view and write the deployment notes.
        """

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Returns true when a self-test was requested (and started).
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--selftest") else { return false }

        let name = arguments.indices.contains(flagIndex + 1) ? arguments[flagIndex + 1] : "apple"
        guard let engine = TranscriptionEngine(rawValue: name) else {
            report("unknown engine '\(name)'; expected one of \(TranscriptionEngine.allCases.map(\.rawValue))")
            return true
        }
        guard let sample = Bundle.main.url(forResource: "sample", withExtension: "wav") else {
            report("sample.wav is missing from the bundle")
            return true
        }

        // Lets a self-test point at a locally running backend without going
        // through the Settings screen: --backend http://localhost:8000 --api-key xyz
        if let url = value(after: "--backend", in: arguments) {
            AppConfig.shared.backendBaseURL = url
        }
        if let key = value(after: "--api-key", in: arguments) {
            AppConfig.shared.backendAPIKey = key
        }

        Task { @MainActor in
            await run(engine: engine, sample: sample)
        }
        return true
    }

    @MainActor
    private static func run(engine: TranscriptionEngine, sample: URL) async {
        report("=== self-test: \(engine.displayName) ===")
        let service = EngineRegistry.shared.service(for: engine)

        switch await service.readiness() {
        case .ready:
            report("readiness: ready")
        case .needsModelDownload(let size):
            report("readiness: needs download\(size.map { " (\($0))" } ?? "")")
        case .unavailable(let reason):
            report("readiness: UNAVAILABLE — \(reason)")
        }

        do {
            let outcome = try await service.transcribe(audioURL: sample) { update in
                let percent = update.fraction.map { " \(Int($0 * 100))%" } ?? ""
                report("  … \(update.stage)\(percent)")
            }
            report("model:      \(outcome.modelName)")
            report("latency:    \(outcome.latencyMs) ms")
            report("stages:     \(outcome.stageSummary)")
            report("words:      \(outcome.wordCount)")
            report("confidence: \(outcome.confidence.map { String(format: "%.3f", $0) } ?? "n/a")")
            report("transcript: \(outcome.bestTranscript)")
            if let polished = outcome.polishedTranscript {
                report("polished:   \(polished)")
            }
            let agreement = WordDiff.agreementRate(
                WordDiff.align(transcripts: [expected, outcome.bestTranscript])
            )
            report(String(format: "agreement vs expected: %.0f%%", agreement * 100))
            report("=== self-test PASSED ===")
        } catch {
            report("=== self-test FAILED: \(error.localizedDescription) ===")
        }
    }

    nonisolated private static func report(_ message: String) {
        // Both, so it shows up under `simctl spawn log stream` and in the console.
        Logger(subsystem: Log.subsystem, category: "selftest").info("\(message, privacy: .public)")
        print("SELFTEST \(message)")
    }
}
#endif
