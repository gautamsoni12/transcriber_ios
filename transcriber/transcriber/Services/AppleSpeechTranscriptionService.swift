import AVFoundation
import Foundation
import Speech
import OSLog

/// Local (Apple): iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`, fully offline.
///
/// The locale model is fetched once through `AssetInventory`; after that the
/// engine never touches the network.
nonisolated final class AppleSpeechTranscriptionService: TranscriptionService {
    let engine: TranscriptionEngine = .apple
    private let requestedLocale: Locale

    init(locale: Locale = .current) {
        self.requestedLocale = locale
    }

    var modelName: String {
        get async {
            let tag = await supportedLocale()?.identifier(.bcp47) ?? requestedLocale.identifier
            return "Apple SpeechTranscriber (\(tag))"
        }
    }

    func readiness() async -> EngineReadiness {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable(reason: "SpeechTranscriber isn't available on this device.")
        }
        guard let locale = await supportedLocale() else {
            return .unavailable(reason: "\(requestedLocale.identifier) isn't a supported SpeechTranscriber locale.")
        }
        switch await AssetInventory.status(forModules: [makeTranscriber(locale: locale)]) {
        case .installed:
            return .ready
        case .supported, .downloading:
            return .needsModelDownload(approximateSize: nil)
        case .unsupported:
            return .unavailable(reason: "No on-device model for \(locale.identifier).")
        @unknown default:
            return .needsModelDownload(approximateSize: nil)
        }
    }

    func prepare(progress: @escaping @Sendable (EngineProgress) -> Void) async throws {
        guard let locale = await supportedLocale() else {
            throw TranscriptionError.modelUnavailable("\(requestedLocale.identifier) is not supported")
        }
        let transcriber = makeTranscriber(locale: locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.apple.info("downloading speech assets for \(locale.identifier, privacy: .public)")
            progress(EngineProgress(stage: "Downloading Apple speech model", fraction: 0))

            // Polling the Progress object keeps download reporting simple.
            let tracked = request.progress
            let poller = Task {
                while !Task.isCancelled {
                    progress(EngineProgress(
                        stage: "Downloading Apple speech model",
                        fraction: tracked.fractionCompleted
                    ))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { poller.cancel() }
            try await request.downloadAndInstall()
            progress(EngineProgress(stage: "Downloading Apple speech model", fraction: 1))
            Log.apple.info("speech assets installed")
        }

        // Reserving keeps the locale's model resident for this app.
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    func transcribe(
        audioURL: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void
    ) async throws -> TranscriptionOutcome {
        // One timeline across prepare + transcribe, so a first-run model
        // download shows up as its own stage instead of silently inflating the
        // latency we compare engines on.
        let timeline = StageTimeline(label: "apple", logger: Log.apple)
        try await prepare(progress: progress)
        timeline.mark("model ready")

        do {
            return try await analyze(audioURL: audioURL, progress: progress, timeline: timeline)
        } catch {
            // On-device transcription generally doesn't need speech-recognition
            // authorization, so we don't prompt up front. If the system says
            // otherwise, ask once and retry rather than failing the recording.
            guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { throw error }
            Log.apple.info("retrying after requesting speech authorization")
            _ = await Self.requestAuthorization()
            return try await analyze(audioURL: audioURL, progress: progress, timeline: timeline)
        }
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func analyze(
        audioURL: URL,
        progress: @escaping @Sendable (EngineProgress) -> Void,
        timeline: StageTimeline
    ) async throws -> TranscriptionOutcome {
        guard let locale = await supportedLocale() else {
            throw TranscriptionError.modelUnavailable("\(requestedLocale.identifier) is not supported")
        }
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscriptionError.audioUnreadable(error.localizedDescription)
        }
        timeline.mark("open audio")

        progress(EngineProgress(stage: "Transcribing on device"))

        // Results stream while `analyzeSequence` pushes the file through.
        let collector = Task {
            var accumulated = AttributedString()
            for try await result in transcriber.results {
                accumulated.append(result.text)
            }
            return accumulated
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }

        let attributed = try await collector.value
        timeline.mark("transcribe")

        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }

        return TranscriptionOutcome(
            engine: .apple,
            modelName: await modelName,
            rawTranscript: text,
            polishedTranscript: nil,
            title: nil,
            summary: nil,
            confidence: Self.averageConfidence(of: attributed),
            latencyMs: timeline.totalMilliseconds,
            stages: timeline.finish()
        )
    }

    // MARK: - Helpers

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )
    }

    private func supportedLocale() async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            return match
        }
        // Fall back to US English so a device in an unsupported locale still works.
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    /// Mean of the per-run confidence attribute, weighted by run length.
    private static func averageConfidence(of text: AttributedString) -> Double? {
        var weightedSum = 0.0
        var weight = 0.0
        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let length = Double(text[run.range].characters.count)
            weightedSum += confidence * length
            weight += length
        }
        guard weight > 0 else { return nil }
        return weightedSum / weight
    }
}
