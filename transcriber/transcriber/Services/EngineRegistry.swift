import Foundation
import Observation

/// Builds the concrete `TranscriptionService` for each mode from current config.
///
/// This is the only place that knows which class implements which mode; the
/// views only ever see `any TranscriptionService`.
@MainActor
@Observable
final class EngineRegistry {
    static let shared = EngineRegistry()

    private let config = AppConfig.shared
    private let apple = AppleSpeechTranscriptionService()
    private var whisper: WhisperKitTranscriptionService?

    private init() {}

    func service(for engine: TranscriptionEngine) -> any TranscriptionService {
        switch engine {
        case .apple: apple
        case .whisper: whisperService()
        case .cloud: CloudTranscriptionService(client: backendClient())
        case .auto: AutoTranscriptionService(local: apple, client: backendClient())
        }
    }

    /// Recreated when the user switches model variant in Settings, so the actor's
    /// cached pipeline is dropped along with it.
    private func whisperService() -> WhisperKitTranscriptionService {
        if let whisper, whisper.variant == config.whisperModelVariant { return whisper }
        let service = WhisperKitTranscriptionService(variant: config.whisperModelVariant)
        whisper = service
        return service
    }

    func backendClient() -> BackendClient? {
        try? BackendClient(config: config)
    }

    var isBackendConfigured: Bool { config.isBackendConfigured }
}
