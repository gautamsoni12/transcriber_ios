import Foundation
import Observation

/// Runtime configuration: backend endpoint, API key, and engine preferences.
///
/// Nothing here is hardcoded. Values are seeded once from a gitignored
/// `Resources/Config.plist` (see `Config.example.plist`) and thereafter live in
/// the Keychain (secret) and `UserDefaults` (non-secret), editable in Settings.
@Observable
final class AppConfig {
    static let shared = AppConfig()

    private enum Key {
        static let baseURL = "backendBaseURL"
        static let apiKey = "backendAPIKey"
        static let whisperModel = "whisperModelVariant"
        static let seeded = "configSeededFromPlist"
    }

    var backendBaseURL: String {
        didSet { UserDefaults.standard.set(backendBaseURL, forKey: Key.baseURL) }
    }

    var backendAPIKey: String {
        didSet { Keychain.set(backendAPIKey, for: Key.apiKey) }
    }

    /// `openai_whisper-small` by default; Settings can drop it to `base`.
    var whisperModelVariant: String {
        didSet { UserDefaults.standard.set(whisperModelVariant, forKey: Key.whisperModel) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Key.seeded) {
            Self.seedFromBundledPlist()
            defaults.set(true, forKey: Key.seeded)
        }
        backendBaseURL = defaults.string(forKey: Key.baseURL) ?? ""
        backendAPIKey = Keychain.string(for: Key.apiKey) ?? ""
        whisperModelVariant = defaults.string(forKey: Key.whisperModel) ?? WhisperModelVariant.small.rawValue
    }

    /// True when the cloud-backed engines have somewhere to call.
    var isBackendConfigured: Bool {
        resolvedBaseURL != nil && !backendAPIKey.isEmpty
    }

    var resolvedBaseURL: URL? {
        let trimmed = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    /// Copies developer defaults out of `Config.plist` on very first launch.
    private static func seedFromBundledPlist() {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }

        if let base = plist["BackendBaseURL"] as? String, !base.isEmpty {
            UserDefaults.standard.set(base, forKey: Key.baseURL)
        }
        if let key = plist["BackendAPIKey"] as? String, !key.isEmpty {
            Keychain.set(key, for: Key.apiKey)
        }
    }
}

nonisolated enum WhisperModelVariant: String, CaseIterable, Identifiable, Sendable {
    case small = "openai_whisper-small"
    case base = "openai_whisper-base"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "small (higher accuracy, ~480 MB)"
        case .base: "base (faster, ~150 MB)"
        }
    }
}
