import Foundation

/// Word-level alignment across two or more transcripts.
///
/// The compare view needs to show *where* engines disagree, which means the
/// three transcripts have to be lined up column by column even though they have
/// different lengths. This does a progressive LCS merge: align source 0 and 1,
/// then align the merged columns against source 2, and so on.
nonisolated enum WordDiff {
    /// One aligned position. `tokens[i]` is source `i`'s word there, or `nil`
    /// if that source has nothing at this position.
    struct Column: Identifiable, Hashable, Sendable {
        var id: Int
        var tokens: [String?]
        /// True when every source supplied a word and they all normalise equal.
        var agrees: Bool
    }

    /// Guard rail so a runaway transcript can't allocate a giant DP table.
    static let maxTokens = 3_000

    static func align(_ sources: [[String]]) -> [Column] {
        guard let first = sources.first else { return [] }
        let clipped = sources.map { Array($0.prefix(maxTokens)) }

        var columns: [[String?]] = clipped[0].map { [$0] }
        var keys: [String] = clipped[0].map(normalize)
        _ = first

        for index in 1..<clipped.count {
            let tokens = clipped[index]
            let tokenKeys = tokens.map(normalize)
            let pairs = alignPair(keys, tokenKeys)

            var mergedColumns: [[String?]] = []
            var mergedKeys: [String] = []
            mergedColumns.reserveCapacity(pairs.count)

            for (left, right) in pairs {
                var row: [String?] = left.map { columns[$0] } ?? Array(repeating: nil, count: index)
                row.append(right.map { tokens[$0] })
                mergedColumns.append(row)
                if let left {
                    mergedKeys.append(keys[left])
                } else if let right {
                    mergedKeys.append(tokenKeys[right])
                } else {
                    mergedKeys.append("")
                }
            }
            columns = mergedColumns
            keys = mergedKeys
        }

        return columns.enumerated().map { offset, tokens in
            Column(id: offset, tokens: tokens, agrees: allAgree(tokens))
        }
    }

    /// Convenience: align raw transcript strings.
    static func align(transcripts: [String]) -> [Column] {
        align(transcripts.map(\.wordTokens))
    }

    /// Fraction of positions where every source agrees — a quick similarity score.
    static func agreementRate(_ columns: [Column]) -> Double {
        guard !columns.isEmpty else { return 0 }
        return Double(columns.filter(\.agrees).count) / Double(columns.count)
    }

    // MARK: - Internals

    /// Compare words ignoring case and surrounding punctuation, so "Hello," and
    /// "hello" count as agreement — engines differ on punctuation constantly and
    /// flagging that as a disagreement would bury the real ones.
    static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func allAgree(_ tokens: [String?]) -> Bool {
        guard tokens.allSatisfy({ $0 != nil }) else { return false }
        let normalized = tokens.compactMap { $0.map(normalize) }
        guard let head = normalized.first, !head.isEmpty else { return false }
        return normalized.allSatisfy { $0 == head }
    }

    /// Classic LCS backtrack, returning `(leftIndex?, rightIndex?)` in order.
    private static func alignPair(_ left: [String], _ right: [String]) -> [(Int?, Int?)] {
        let n = left.count
        let m = right.count
        if n == 0 { return (0..<m).map { (nil, $0) } }
        if m == 0 { return (0..<n).map { ($0, nil) } }

        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = left[i] == right[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result: [(Int?, Int?)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if left[i] == right[j] {
                result.append((i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append((i, nil)); i += 1
            } else {
                result.append((nil, j)); j += 1
            }
        }
        while i < n { result.append((i, nil)); i += 1 }
        while j < m { result.append((nil, j)); j += 1 }
        return result
    }
}
