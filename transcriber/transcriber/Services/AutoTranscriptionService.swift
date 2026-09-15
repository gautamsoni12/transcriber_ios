import Foundation
import OSLog

/// Auto: run Apple locally for an immediate transcript, then — if we're online
/// and the backend is configured — ask Claude to clean it up and swap that in.
///
/// Any network or backend failure leaves the local result in place.
nonisolated struct AutoTranscriptionService: TranscriptionService {
    let engine: TranscriptionEngine = .auto
    let local: AppleSpeechTranscriptionService
    let client: BackendClient?

    init(local: AppleSpeechTranscriptionService, client: BackendClient?) {
        self.local = local
        self.client = client
    }

    var modelName: String {
        get async {
            let base = await local.modelName
            return client == nil ? base : "\(base) + claude-sonnet-5"
        }
    }

    /// Auto is usable whenever the local engine is — the cloud half is optional.
    func readiness() async -> EngineReadiness {
        await local.readiness()
    }

    func prepare(progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        try await local.prepare(progress: progress)
    }

    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> TranscriptionOutcome {
        let timeline = StageTimeline(label: "auto", logger: Log.auto)

        var outcome = try await local.transcribe(audioURL: audioURL, progress: progress)
        timeline.mark("local")
        // Show the local text immediately; the enhance pass may replace it.
        progress(EngineProgress(stage: "Local transcript ready", partialText: outcome.rawTranscript))

        var stages = outcome.stages.map {
            StageTiming(name: "local.\($0.name)", milliseconds: $0.milliseconds)
        }

        guard let client else {
            Log.auto.info("no backend configured — keeping local-only result")
            return Self.finish(outcome: &outcome, stages: stages, timeline: timeline, enhanced: false)
        }
        guard NetworkMonitor.shared.isOnline else {
            Log.auto.info("offline — keeping local-only result")
            return Self.finish(outcome: &outcome, stages: stages, timeline: timeline, enhanced: false)
        }

        progress(EngineProgress(stage: "Improving with Claude", partialText: outcome.rawTranscript))
        do {
            let enhanced = try await client.enhance(transcript: outcome.rawTranscript)
            timeline.mark("enhance")
            stages.append(StageTiming(name: "enhance", milliseconds: enhanced.latencyMs))
            outcome.polishedTranscript = enhanced.polishedTranscript
            outcome.title = enhanced.title
            outcome.summary = enhanced.summary
            outcome.modelName = "\(outcome.modelName) + \(enhanced.model)"
            Log.auto.info("enhanced via backend in \(enhanced.latencyMs)ms")
            return Self.finish(outcome: &outcome, stages: stages, timeline: timeline, enhanced: true)
        } catch {
            // Network or backend problem: the local transcript still stands.
            Log.auto.error("enhance failed, falling back to local: \(error.localizedDescription, privacy: .public)")
            stages.append(StageTiming(name: "enhance failed", milliseconds: timeline.totalMilliseconds))
            return Self.finish(outcome: &outcome, stages: stages, timeline: timeline, enhanced: false)
        }
    }

    private static func finish(
        outcome: inout TranscriptionOutcome,
        stages: [StageTiming],
        timeline: StageTimeline,
        enhanced: Bool
    ) -> TranscriptionOutcome {
        outcome.engine = .auto
        outcome.stages = stages
        outcome.latencyMs = timeline.totalMilliseconds
        _ = timeline.finish()
        return outcome
    }
}
