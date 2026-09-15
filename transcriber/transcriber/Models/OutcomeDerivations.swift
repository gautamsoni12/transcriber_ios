import Foundation

/// Fallbacks for engines that don't produce a title/summary of their own.
///
/// Apple and Whisper run fully offline, so there may be no Claude pass at all;
/// the detail screen can still show something sensible and offer to generate a
/// real one later.
nonisolated extension TranscriptionOutcome {
    var derivedTitle: String {
        if let title, !title.isEmpty { return title }
        let words = bestTranscript.wordTokens.prefix(7)
        guard !words.isEmpty else { return "Untitled note" }
        let joined = words.joined(separator: " ")
        return bestTranscript.wordTokens.count > 7 ? joined + "…" : joined
    }

    var derivedSummary: String {
        if let summary, !summary.isEmpty { return summary }
        let sentences = bestTranscript
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sentences.prefix(2).joined(separator: ". ")
    }

    /// True when a Claude pass actually wrote the title/summary.
    var hasGeneratedMetadata: Bool {
        !(title ?? "").isEmpty && !(summary ?? "").isEmpty
    }
}
