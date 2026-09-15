import Foundation
import OSLog

/// Cloud: uploads the recording to the backend, which runs faster-whisper and
/// then has Claude punctuate it and write a title + summary.
nonisolated struct CloudTranscriptionService: TranscriptionService {
    let engine: TranscriptionEngine = .cloud
    let client: BackendClient?

    init(client: BackendClient?) {
        self.client = client
    }

    var modelName: String {
        get async { "faster-whisper small + claude-sonnet-5" }
    }

    func readiness() async -> EngineReadiness {
        guard client != nil else {
            return .unavailable(reason: "Set the backend URL and API key in Settings.")
        }
        guard NetworkMonitor.shared.isOnline else {
            return .unavailable(reason: "No network connection.")
        }
        return .ready
    }

    func prepare(progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        guard client != nil else { throw TranscriptionError.backendNotConfigured }
    }

    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> TranscriptionOutcome {
        guard let client else { throw TranscriptionError.backendNotConfigured }
        let timeline = StageTimeline(label: "cloud", logger: Log.cloud)

        progress(EngineProgress(stage: "Uploading audio"))
        let response = try await client.transcribe(audioURL: audioURL)
        timeline.mark("round trip")

        // The backend reports its own internal time so we can separate it from
        // upload/network overhead.
        let networkMs = max(0, timeline.totalMilliseconds - response.latencyMs)
        var stages = timeline.snapshotStages()
        for stage in response.stages ?? [] {
            stages.append(StageTiming(name: "server.\(stage.name)", milliseconds: stage.milliseconds))
        }
        stages.append(StageTiming(name: "network", milliseconds: networkMs))

        let raw = response.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw TranscriptionError.emptyTranscript }

        Log.cloud.info("cloud done: server \(response.latencyMs)ms, network \(networkMs)ms")

        return TranscriptionOutcome(
            engine: .cloud,
            modelName: response.model,
            rawTranscript: raw,
            polishedTranscript: response.polishedTranscript,
            title: response.title,
            summary: response.summary,
            confidence: response.asrConfidence,
            latencyMs: timeline.totalMilliseconds,
            stages: stages
        )
    }
}

nonisolated extension StageTimeline {
    /// `finish()` logs; this just reads the stages for callers that append their own.
    func snapshotStages() -> [StageTiming] { snapshot }
}
