import SwiftData
import SwiftUI
import OSLog

/// Runs Apple, Whisper and Cloud over the same recording and diffs the results.
struct CompareView: View {
    @Bindable var note: Note

    @State private var states: [TranscriptionEngine: CompareState] = [:]
    @State private var isRunning = false

    private let engines = TranscriptionEngine.comparable

    var body: some View {
        List {
            controlSection

            if !columns.isEmpty {
                agreementSection
                ForEach(availableEngines, id: \.self) { engine in
                    transcriptSection(for: engine)
                }
                disagreementSection
            }

            metricsSection
        }
        .navigationTitle("Compare engines")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var controlSection: some View {
        Section {
            Button {
                Task { await runAll() }
            } label: {
                HStack {
                    Label(isRunning ? "Running…" : "Run all engines", systemImage: "play.circle")
                    Spacer()
                    if isRunning { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isRunning)

            ForEach(engines, id: \.self) { engine in
                HStack(alignment: .top) {
                    EngineBadge(engine: engine, compact: true)
                    Spacer()
                    statusView(for: engine)
                }
            }
        } footer: {
            Text("Whisper may take a while on long recordings, and downloads its model the first time. Cloud needs the backend configured in Settings.")
        }
    }

    @ViewBuilder
    private func statusView(for engine: TranscriptionEngine) -> some View {
        switch states[engine] {
        case .running(let stage, let fraction):
            VStack(alignment: .trailing, spacing: 2) {
                Text(stage).font(.caption)
                if let fraction, fraction > 0 {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .done(let run):
            Text("\(run.wordCount) words · \(run.latencyMs) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        case nil:
            Text(note.run(for: engine) == nil ? "not run" : "from earlier run")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var agreementSection: some View {
        Section("Agreement") {
            let rate = WordDiff.agreementRate(columns)
            HStack {
                Text(rate, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.monospacedDigit().weight(.semibold))
                Text("of \(columns.count) aligned positions match across \(availableEngines.count) engines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func transcriptSection(for engine: TranscriptionEngine) -> some View {
        Section {
            Text(highlighted(for: engine))
                .textSelection(.enabled)
        } header: {
            HStack {
                EngineBadge(engine: engine, compact: true)
                Spacer()
                if let run = transcriptRun(for: engine) {
                    Text(run.modelName).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var disagreementSection: some View {
        let rows = columns.filter { !$0.agrees }
        if !rows.isEmpty {
            Section {
                ForEach(rows.prefix(80)) { column in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(availableEngines.enumerated()), id: \.offset) { index, engine in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(engine.shortName)
                                    .font(.caption2)
                                    .foregroundStyle(engine.tint)
                                Text(column.tokens.indices.contains(index) ? (column.tokens[index] ?? "—") : "—")
                                    .font(.callout)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if rows.count > 80 {
                    Text("+ \(rows.count - 80) more differences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Where they disagree (\(rows.count))")
            }
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        let runs = availableEngines.compactMap { transcriptRun(for: $0) }
        if !runs.isEmpty {
            Section("Metrics") {
                ForEach(runs, id: \.id) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        EngineBadge(engine: run.engine)
                        RunMetricsView(run: run, audioDuration: note.durationSeconds)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Data

    /// Engines that have a transcript to show, in a stable order.
    private var availableEngines: [TranscriptionEngine] {
        engines.filter { transcriptRun(for: $0) != nil }
    }

    private func transcriptRun(for engine: TranscriptionEngine) -> EngineRun? {
        if case .done(let run) = states[engine] { return run }
        return note.run(for: engine)
    }

    private var columns: [WordDiff.Column] {
        let transcripts = availableEngines.compactMap { transcriptRun(for: $0)?.bestTranscript }
        guard transcripts.count >= 2 else { return [] }
        return WordDiff.align(transcripts: transcripts)
    }

    /// Transcript with disagreements highlighted, and gaps marked where this
    /// engine dropped a word the others heard.
    private func highlighted(for engine: TranscriptionEngine) -> AttributedString {
        guard let index = availableEngines.firstIndex(of: engine) else { return AttributedString() }
        var output = AttributedString()
        for column in columns {
            guard column.tokens.indices.contains(index) else { continue }
            if let token = column.tokens[index] {
                var piece = AttributedString(token + " ")
                if !column.agrees {
                    piece.backgroundColor = .yellow.opacity(0.35)
                }
                output.append(piece)
            } else {
                var gap = AttributedString("• ")
                gap.foregroundColor = .red.opacity(0.7)
                gap.backgroundColor = .red.opacity(0.12)
                output.append(gap)
            }
        }
        return output
    }

    // MARK: - Actions

    /// Sequential on purpose: Whisper's CoreML pipeline is memory-hungry and
    /// running it alongside the others made the POC jetsam on device.
    private func runAll() async {
        isRunning = true
        defer { isRunning = false }

        let audioURL = note.audioURL
        for engine in engines {
            let service = EngineRegistry.shared.service(for: engine)
            if case .unavailable(let reason) = await service.readiness() {
                states[engine] = .failed(reason)
                continue
            }

            states[engine] = .running(stage: "Starting", fraction: nil)
            let sink: @Sendable (EngineProgress) -> Void = { update in
                Task { @MainActor in
                    states[engine] = .running(stage: update.stage, fraction: update.fraction)
                }
            }

            do {
                let outcome = try await service.transcribe(audioURL: audioURL, progress: sink)
                let run = replaceRun(with: outcome, engine: engine)
                states[engine] = .done(run)
            } catch {
                Log.store.error("compare \(engine.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                states[engine] = .failed(error.localizedDescription)
            }
        }

        try? note.modelContext?.save()
    }

    /// One run per engine per note — re-running replaces the previous numbers.
    private func replaceRun(with outcome: TranscriptionOutcome, engine: TranscriptionEngine) -> EngineRun {
        if let existing = note.run(for: engine) {
            note.runs.removeAll { $0.id == existing.id }
            note.modelContext?.delete(existing)
        }
        let run = outcome.makeRun()
        run.engine = engine
        note.runs.append(run)
        return run
    }
}

private enum CompareState {
    case running(stage: String, fraction: Double?)
    case done(EngineRun)
    case failed(String)
}
