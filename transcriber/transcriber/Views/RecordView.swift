import SwiftData
import SwiftUI
import OSLog

/// Record screen: pick a mode, capture audio, transcribe, save the note.
struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var recorder = AudioRecorder()
    @State private var runner = TranscriptionRunner()
    @State private var engine: TranscriptionEngine = .apple
    @State private var readiness: EngineReadiness?
    @State private var permissionDenied = false
    @State private var savedNoteID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                enginePicker

                Spacer()

                if runner.isRunning {
                    transcribingState
                } else {
                    recordingState
                }

                Spacer()

                if let error = runner.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                controls
            }
            .padding()
            .navigationTitle("New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        runner.cancel()
                        dismiss()
                    }
                    .disabled(runner.isRunning)
                }
            }
            .task(id: engine) { await refreshReadiness() }
            .alert("Microphone access needed", isPresented: $permissionDenied) {
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text("Enable microphone access in Settings ▸ Transcriber to record notes.")
            }
        }
        .interactiveDismissDisabled(recorder.isRecording || runner.isRunning)
    }

    // MARK: - Sections

    private var enginePicker: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $engine) {
                ForEach(TranscriptionEngine.allCases) { mode in
                    Text(mode.shortName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(recorder.isRecording || runner.isRunning)

            Text(engine.blurb)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            readinessNote
        }
    }

    @ViewBuilder
    private var readinessNote: some View {
        switch readiness {
        case .needsModelDownload(let size):
            Label(
                "First use downloads the model\(size.map { " (\($0))" } ?? "").",
                systemImage: "arrow.down.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        default:
            EmptyView()
        }
    }

    private var recordingState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(engine.tint.opacity(0.15))
                    .frame(width: 180, height: 180)
                    .scaleEffect(recorder.isRecording ? 1 + recorder.level * 0.25 : 1)
                    .animation(.easeOut(duration: 0.08), value: recorder.level)
                Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(engine.tint)
            }
            Text(recorder.elapsed.clockString)
                .font(.system(.largeTitle, design: .monospaced))
                .contentTransition(.numericText())
            Text(recorder.isRecording ? "Recording at 16 kHz mono" : "Ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transcribingState: some View {
        VStack(spacing: 16) {
            EngineProgressView(stage: runner.stage ?? "Working", fraction: runner.fraction)
                .frame(maxWidth: 320)
            if let partial = runner.partialText {
                ScrollView {
                    Text(partial)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if runner.isRunning {
            Text("Keep the app open while this finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if recorder.isRecording {
            Button {
                Task { await stopAndTranscribe() }
            } label: {
                Label("Stop & transcribe", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
        } else {
            Button {
                Task { await startRecording() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(engine.tint)
            .disabled(isEngineUnavailable)
        }
    }

    private var isEngineUnavailable: Bool {
        if case .unavailable = readiness { return true }
        return false
    }

    // MARK: - Actions

    private func refreshReadiness() async {
        readiness = nil
        readiness = await EngineRegistry.shared.service(for: engine).readiness()
    }

    private func startRecording() async {
        guard await recorder.requestPermission() else {
            permissionDenied = true
            return
        }
        do {
            _ = try recorder.start()
        } catch {
            runner.cancel()
            permissionDenied = false
            Log.recording.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopAndTranscribe() async {
        guard let url = recorder.stop() else {
            Log.recording.error("nothing captured")
            return
        }
        let duration = AudioStore.duration(of: url)
        guard let outcome = await runner.run(engine: engine, audioURL: url) else { return }

        let note = Note(
            title: outcome.derivedTitle,
            summary: outcome.derivedSummary,
            audioFileName: url.lastPathComponent,
            durationSeconds: duration,
            primaryEngine: engine
        )
        let run = outcome.makeRun()
        note.runs.append(run)
        context.insert(note)
        do {
            try context.save()
            Log.store.info("saved note \(note.id, privacy: .public) via \(engine.rawValue, privacy: .public)")
        } catch {
            Log.store.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
        savedNoteID = note.id
        dismiss()
    }
}
