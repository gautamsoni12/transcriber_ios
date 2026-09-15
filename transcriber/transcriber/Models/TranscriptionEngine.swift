import Foundation
import SwiftUI

/// The four user-selectable processing modes.
nonisolated enum TranscriptionEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case apple
    case whisper
    case cloud
    case auto

    var id: String { rawValue }

    /// Label used in the record screen's segmented control.
    var shortName: String {
        switch self {
        case .apple: "Apple"
        case .whisper: "Whisper"
        case .cloud: "Cloud"
        case .auto: "Auto"
        }
    }

    var displayName: String {
        switch self {
        case .apple: "Local (Apple)"
        case .whisper: "Local (Whisper)"
        case .cloud: "Cloud"
        case .auto: "Auto"
        }
    }

    var blurb: String {
        switch self {
        case .apple: "Apple's on-device SpeechAnalyzer. Fully offline, fastest to start."
        case .whisper: "WhisperKit CoreML on device. Fully offline, slower but often more accurate."
        case .cloud: "Uploads audio to the backend: faster-whisper, then Claude polishes it."
        case .auto: "Instant Apple result, then Claude improves it in the background if you're online."
        }
    }

    var systemImage: String {
        switch self {
        case .apple: "apple.logo"
        case .whisper: "waveform.circle"
        case .cloud: "cloud"
        case .auto: "wand.and.sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .apple: .blue
        case .whisper: .purple
        case .cloud: .teal
        case .auto: .orange
        }
    }

    /// Engines that actually produce a transcript from audio (`auto` composes these).
    static var comparable: [TranscriptionEngine] { [.apple, .whisper, .cloud] }

    var requiresNetwork: Bool { self == .cloud }
}
