import Foundation

/// The single seam every engine sits behind.
///
/// `AppleSpeechTranscriptionService`, `WhisperKitTranscriptionService`,
/// `CloudTranscriptionService` and `AutoTranscriptionService` are the only
/// conformances; nothing in the UI layer imports `Speech` or `WhisperKit`.
nonisolated protocol TranscriptionService: Sendable {
    var engine: TranscriptionEngine { get }

    /// Concrete model identifier recorded on every `EngineRun`.
    var modelName: String { get async }

    /// Whether the engine can run right now, and if not, what it needs.
    func readiness() async -> EngineReadiness

    /// Downloads/loads whatever the engine needs. Safe to call when already ready.
    func prepare(progress: @escaping @Sendable (EngineProgress) -> Void) async throws

    /// Transcribes a local audio file.
    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> TranscriptionOutcome
}

extension TranscriptionService {
    func transcribe(audioURL: URL) async throws -> TranscriptionOutcome {
        try await transcribe(audioURL: audioURL, progress: { _ in })
    }
}

/// What an engine needs before it can be used.
nonisolated enum EngineReadiness: Sendable, Equatable {
    /// Ready to transcribe immediately.
    case ready
    /// Works, but the first run has to fetch a model.
    case needsModelDownload(approximateSize: String?)
    /// Can't run at all here (no backend configured, unsupported locale, simulator limits…).
    case unavailable(reason: String)

    var isReady: Bool { self == .ready }
}

/// Progress pushed up to the UI while an engine works.
nonisolated struct EngineProgress: Sendable {
    /// Human-readable stage, e.g. "Downloading model", "Transcribing", "Polishing with Claude".
    var stage: String
    /// 0…1 when known (model downloads), `nil` for indeterminate work.
    var fraction: Double?
    /// Partial transcript, if the engine streams one.
    var partialText: String?

    init(stage: String, fraction: Double? = nil, partialText: String? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.partialText = partialText
    }
}

/// Everything one engine produced from one audio file.
nonisolated struct TranscriptionOutcome: Sendable {
    var engine: TranscriptionEngine
    var modelName: String
    var rawTranscript: String
    /// Non-nil when a cleanup pass ran (cloud/auto).
    var polishedTranscript: String?
    /// Claude-generated, only for engines that produce them.
    var title: String?
    var summary: String?
    var confidence: Double?
    var latencyMs: Int
    var stages: [StageTiming]

    var bestTranscript: String {
        if let polishedTranscript, !polishedTranscript.isEmpty { return polishedTranscript }
        return rawTranscript
    }

    var wordCount: Int { bestTranscript.wordTokens.count }

    var stageSummary: String {
        stages.map { "\($0.name) \($0.milliseconds)ms" }.joined(separator: " · ")
    }

    func makeRun() -> EngineRun {
        EngineRun(
            engine: engine,
            modelName: modelName,
            rawTranscript: rawTranscript,
            polishedTranscript: polishedTranscript,
            latencyMs: latencyMs,
            wordCount: wordCount,
            confidence: confidence,
            stageSummary: stageSummary
        )
    }
}

nonisolated enum TranscriptionError: LocalizedError {
    case permissionDenied
    case modelUnavailable(String)
    case audioUnreadable(String)
    case backendNotConfigured
    case backend(status: Int, message: String)
    case emptyTranscript
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech recognition permission was denied. Enable it in Settings ▸ Transcriber."
        case let .modelUnavailable(detail):
            "The speech model isn't available: \(detail)"
        case let .audioUnreadable(detail):
            "Couldn't read the recording: \(detail)"
        case .backendNotConfigured:
            "Set the backend URL and API key in Settings first."
        case let .backend(status, message):
            "Backend returned \(status): \(message)"
        case .emptyTranscript:
            "No speech was recognised in this recording."
        case .cancelled:
            "Transcription was cancelled."
        }
    }
}

nonisolated extension String {
    /// Word tokenisation shared by word counts and the compare-view diff.
    var wordTokens: [String] {
        split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
