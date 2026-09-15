import SwiftData
import SwiftUI
import OSLog

struct NoteDetailView: View {
    @Bindable var note: Note

    @State private var player = AudioPlayer()
    @State private var showPolished = true
    @State private var selectedEngine: TranscriptionEngine?
    @State private var isGeneratingMetadata = false
    @State private var metadataError: String?

    var body: some View {
        List {
            playbackSection
            summarySection
            transcriptSection
            metricsSection
            compareSection
        }
        .navigationTitle(note.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            player.load(url: note.audioURL)
            selectedEngine = note.primaryRun?.engine
        }
        .onDisappear { player.stop() }
    }

    private var activeRun: EngineRun? {
        if let selectedEngine, let run = note.run(for: selectedEngine) { return run }
        return note.primaryRun
    }

    // MARK: - Sections

    private var playbackSection: some View {
        Section("Audio") {
            HStack(spacing: 16) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.1)
                    )
                    HStack {
                        Text(player.currentTime.clockString)
                        Spacer()
                        Text(note.durationSeconds.clockString)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            if note.summary.isEmpty {
                Text("No summary yet.").foregroundStyle(.secondary)
            } else {
                Text(note.summary)
            }

            if EngineRegistry.shared.isBackendConfigured {
                Button {
                    Task { await generateMetadata() }
                } label: {
                    HStack {
                        Label("Rewrite title & summary with Claude", systemImage: "sparkles")
                        Spacer()
                        if isGeneratingMetadata { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isGeneratingMetadata || activeRun == nil)
            }

            if let metadataError {
                Text(metadataError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Summary")
        } footer: {
            Text("Recorded \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        Section {
            if note.runs.count > 1 {
                Picker("Engine", selection: Binding(
                    get: { selectedEngine ?? note.primaryEngine },
                    set: { selectedEngine = $0 }
                )) {
                    ForEach(note.runsNewestFirst, id: \.id) { run in
                        Text(run.engine.shortName).tag(run.engine)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let run = activeRun {
                if run.hasPolish {
                    Picker("Version", selection: $showPolished) {
                        Text("Polished").tag(true)
                        Text("Raw").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Text(showPolished ? run.bestTranscript : run.rawTranscript)
                    .textSelection(.enabled)
            } else {
                Text("No transcript.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Transcript")
                Spacer()
                if let run = activeRun { EngineBadge(engine: run.engine, compact: true) }
            }
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        if !note.runs.isEmpty {
            Section("Metrics") {
                ForEach(note.runsNewestFirst, id: \.id) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        EngineBadge(engine: run.engine)
                        RunMetricsView(run: run, audioDuration: note.durationSeconds)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var compareSection: some View {
        Section {
            NavigationLink {
                CompareView(note: note)
            } label: {
                Label("Run all engines", systemImage: "square.split.2x1")
            }
        } footer: {
            Text("Transcribes this same recording with Apple, Whisper and Cloud, then diffs the three transcripts word by word.")
        }
    }

    // MARK: - Actions

    private func generateMetadata() async {
        guard let run = activeRun else { return }
        isGeneratingMetadata = true
        metadataError = nil
        defer { isGeneratingMetadata = false }

        guard let client = EngineRegistry.shared.backendClient() else {
            metadataError = TranscriptionError.backendNotConfigured.localizedDescription
            return
        }
        do {
            let result = try await client.enhance(transcript: run.rawTranscript)
            note.title = result.title
            note.summary = result.summary
            run.polishedTranscript = result.polishedTranscript
            Log.store.info("regenerated metadata for note \(note.id, privacy: .public)")
        } catch {
            metadataError = error.localizedDescription
        }
    }
}
