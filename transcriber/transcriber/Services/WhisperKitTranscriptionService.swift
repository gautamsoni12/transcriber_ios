import Foundation
import WhisperKit
import OSLog

/// Local (Whisper): WhisperKit CoreML, fully offline once the model is on disk.
///
/// An actor because loading a multi-hundred-megabyte CoreML pipeline must not
/// happen twice concurrently; the loaded pipeline is cached between runs.
actor WhisperKitTranscriptionService: TranscriptionService {
    nonisolated let engine: TranscriptionEngine = .whisper
    nonisolated let variant: String

    private static let repo = "argmaxinc/whisperkit-coreml"

    private var pipeline: WhisperKit?

    init(variant: String) {
        self.variant = variant
    }

    nonisolated var modelName: String {
        get async { "WhisperKit \(variant)" }
    }

    /// `~/Library/Application Support/WhisperKitModels` — keeps big models out of
    /// Documents (which is user-visible and backed up).
    nonisolated static var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("WhisperKitModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mirrors HubApi's on-disk layout: `<base>/models/<repo>/<variant>`.
    nonisolated var localModelFolder: URL {
        downloadBaseModelsRoot.appendingPathComponent(variant, isDirectory: true)
    }

    private nonisolated var downloadBaseModelsRoot: URL {
        Self.downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.repo, isDirectory: true)
    }

    nonisolated var isModelDownloaded: Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: localModelFolder.path) else { return false }
        // A complete snapshot has the three compiled CoreML bundles.
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    func readiness() async -> EngineReadiness {
        if pipeline != nil { return .ready }
        if isModelDownloaded { return .ready }
        return .needsModelDownload(approximateSize: Self.approximateSize(for: variant))
    }

    func prepare(progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        try await prepare(progress: progress, timeline: nil)
    }

    private func prepare(
        progress: @escaping @Sendable (EngineProgress) -> Void,
        timeline: StageTimeline?
    ) async throws {
        if pipeline != nil { return }

        if !isModelDownloaded {
            let size = Self.approximateSize(for: variant).map { " (\($0))" } ?? ""
            progress(EngineProgress(stage: "Downloading \(variant)\(size)", fraction: 0))
            Log.whisper.info("downloading \(self.variant, privacy: .public)")
            let variant = self.variant
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.downloadBase,
                from: Self.repo,
                progressCallback: { p in
                    progress(EngineProgress(
                        stage: "Downloading \(variant)\(size)",
                        fraction: p.fractionCompleted
                    ))
                }
            )
            timeline?.mark("download")
        }

        progress(EngineProgress(stage: "Loading Whisper model"))
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: Self.downloadBase,
            modelRepo: Self.repo,
            modelFolder: localModelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            pipeline = try await WhisperKit(config)
        } catch {
            throw TranscriptionError.modelUnavailable(error.localizedDescription)
        }
        timeline?.mark("load")
    }

    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> TranscriptionOutcome {
        let timeline = StageTimeline(label: "whisper", logger: Log.whisper)

        try await prepare(progress: progress, timeline: timeline)
        timeline.mark("model ready")

        guard let pipeline else {
            throw TranscriptionError.modelUnavailable("WhisperKit pipeline failed to load")
        }

        progress(EngineProgress(stage: "Transcribing with \(variant)"))
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            chunkingStrategy: .vad
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipeline.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options
            )
        } catch {
            throw TranscriptionError.audioUnreadable(error.localizedDescription)
        }
        timeline.mark("transcribe")

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }

        return TranscriptionOutcome(
            engine: .whisper,
            modelName: "WhisperKit \(variant)",
            rawTranscript: text,
            polishedTranscript: nil,
            title: nil,
            summary: nil,
            confidence: Self.confidence(from: results),
            latencyMs: timeline.totalMilliseconds,
            stages: timeline.finish()
        )
    }

    // MARK: - Helpers

    /// Whisper reports average log-probability per segment; `exp` maps it back to 0…1.
    private static func confidence(from results: [TranscriptionResult]) -> Double? {
        let segments = results.flatMap(\.segments)
        guard !segments.isEmpty else { return nil }
        let mean = segments.reduce(0.0) { $0 + Double($1.avgLogprob) } / Double(segments.count)
        return min(1, max(0, exp(mean)))
    }

    private static func approximateSize(for variant: String) -> String? {
        switch variant {
        case WhisperModelVariant.small.rawValue: "~480 MB"
        case WhisperModelVariant.base.rawValue: "~150 MB"
        default: nil
        }
    }
}
