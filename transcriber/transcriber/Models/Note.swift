import Foundation
import SwiftData

/// A recording plus everything any engine has produced from it.
@Model
final class Note {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String = ""
    var summary: String = ""

    /// File name inside the app's Documents directory (not an absolute path —
    /// the container path changes between launches).
    var audioFileName: String = ""
    var durationSeconds: Double = 0

    /// Engine the user picked when recording; drives which run is shown first.
    var primaryEngineRaw: String = TranscriptionEngine.apple.rawValue

    @Relationship(deleteRule: .cascade, inverse: \EngineRun.note)
    var runs: [EngineRun] = []

    init(
        title: String = "",
        summary: String = "",
        audioFileName: String,
        durationSeconds: Double,
        primaryEngine: TranscriptionEngine
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.title = title
        self.summary = summary
        self.audioFileName = audioFileName
        self.durationSeconds = durationSeconds
        self.primaryEngineRaw = primaryEngine.rawValue
    }

    var primaryEngine: TranscriptionEngine {
        get { TranscriptionEngine(rawValue: primaryEngineRaw) ?? .apple }
        set { primaryEngineRaw = newValue.rawValue }
    }

    var audioURL: URL {
        AudioStore.documentsDirectory.appendingPathComponent(audioFileName)
    }

    var runsNewestFirst: [EngineRun] {
        runs.sorted { $0.createdAt > $1.createdAt }
    }

    /// The run whose transcript the detail screen shows at the top.
    var primaryRun: EngineRun? {
        runs.first { $0.engine == primaryEngine } ?? runsNewestFirst.first
    }

    func run(for engine: TranscriptionEngine) -> EngineRun? {
        runs.first { $0.engine == engine }
    }

    var displayTitle: String {
        title.isEmpty ? "Untitled note" : title
    }
}

/// One engine's pass over a note's audio, with its metrics.
@Model
final class EngineRun {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var engineRaw: String = TranscriptionEngine.apple.rawValue

    /// Concrete model behind the engine, e.g. `openai_whisper-small` or `faster-whisper small + claude-sonnet-5`.
    var modelName: String = ""

    var rawTranscript: String = ""
    /// Set only when a cleanup pass produced something different from `rawTranscript`.
    var polishedTranscript: String?

    var latencyMs: Int = 0
    var wordCount: Int = 0
    /// 0…1 where the engine exposes it; `nil` for engines that don't (e.g. the Claude polish pass).
    var confidence: Double?

    /// Per-stage timings, rendered as `decode 1204ms · polish 880ms`.
    var stageSummary: String = ""

    var note: Note?

    init(
        engine: TranscriptionEngine,
        modelName: String,
        rawTranscript: String,
        polishedTranscript: String? = nil,
        latencyMs: Int,
        wordCount: Int,
        confidence: Double? = nil,
        stageSummary: String = ""
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.engineRaw = engine.rawValue
        self.modelName = modelName
        self.rawTranscript = rawTranscript
        self.polishedTranscript = polishedTranscript
        self.latencyMs = latencyMs
        self.wordCount = wordCount
        self.confidence = confidence
        self.stageSummary = stageSummary
    }

    var engine: TranscriptionEngine {
        get { TranscriptionEngine(rawValue: engineRaw) ?? .apple }
        set { engineRaw = newValue.rawValue }
    }

    /// What the UI shows: the polished text when one exists, else the raw text.
    var bestTranscript: String {
        if let polishedTranscript, !polishedTranscript.isEmpty { return polishedTranscript }
        return rawTranscript
    }

    var hasPolish: Bool {
        guard let polishedTranscript, !polishedTranscript.isEmpty else { return false }
        return polishedTranscript != rawTranscript
    }

    /// Words per second of audio processed — a size-independent speed number.
    func realtimeFactor(audioDuration: Double) -> Double? {
        guard audioDuration > 0, latencyMs > 0 else { return nil }
        return (Double(latencyMs) / 1000.0) / audioDuration
    }
}
