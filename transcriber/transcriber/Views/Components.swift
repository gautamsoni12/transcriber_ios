import SwiftUI

/// Small coloured engine label used in lists, detail and compare views.
struct EngineBadge: View {
    let engine: TranscriptionEngine
    var compact = false

    var body: some View {
        Label(compact ? engine.shortName : engine.displayName, systemImage: engine.systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(engine.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(engine.tint)
    }
}

/// Model name / latency / words / confidence for one run.
struct RunMetricsView: View {
    let run: EngineRun
    var audioDuration: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.modelName)
                .font(.caption)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { metrics }
                VStack(alignment: .leading, spacing: 4) { metrics }
            }

            if !run.stageSummary.isEmpty {
                Text(run.stageSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var metrics: some View {
        MetricChip(label: "latency", value: formatLatency(run.latencyMs))
        MetricChip(label: "words", value: "\(run.wordCount)")
        if let confidence = run.confidence {
            MetricChip(label: "confidence", value: confidence.formatted(.percent.precision(.fractionLength(0))))
        } else {
            MetricChip(label: "confidence", value: "n/a")
        }
        if let rtf = run.realtimeFactor(audioDuration: audioDuration) {
            MetricChip(label: "×realtime", value: rtf.formatted(.number.precision(.fractionLength(2))))
        }
    }

    private func formatLatency(_ ms: Int) -> String {
        ms < 1_000 ? "\(ms) ms" : "\((Double(ms) / 1000).formatted(.number.precision(.fractionLength(1)))) s"
    }
}

struct MetricChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Inline progress line: stage text plus a bar when the fraction is known.
struct EngineProgressView: View {
    let stage: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage).font(.subheadline)
            }
            if let fraction, fraction > 0 {
                ProgressView(value: min(max(fraction, 0), 1))
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Double {
    /// `m:ss` for durations in the UI.
    var clockString: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
