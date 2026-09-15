import Foundation
import Observation

/// Drives one engine over one file and publishes progress for the UI.
@MainActor
@Observable
final class TranscriptionRunner {
    private(set) var isRunning = false
    private(set) var stage: String?
    private(set) var fraction: Double?
    private(set) var partialText: String?
    private(set) var errorMessage: String?

    private var task: Task<TranscriptionOutcome?, Never>?

    func run(engine: TranscriptionEngine, audioURL: URL) async -> TranscriptionOutcome? {
        guard !isRunning else { return nil }
        isRunning = true
        errorMessage = nil
        partialText = nil
        stage = "Starting \(engine.displayName)"
        fraction = nil

        let service = EngineRegistry.shared.service(for: engine)

        // Progress arrives off the main actor; hop back before touching state.
        let sink: @Sendable (EngineProgress) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stage = update.stage
                self.fraction = update.fraction
                if let text = update.partialText { self.partialText = text }
            }
        }

        let task = Task<TranscriptionOutcome?, Never> {
            do {
                return try await service.transcribe(audioURL: audioURL, progress: sink)
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in self?.errorMessage = message }
                return nil
            }
        }
        self.task = task
        let outcome = await task.value

        isRunning = false
        stage = nil
        fraction = nil
        self.task = nil
        return outcome
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        stage = nil
    }
}
