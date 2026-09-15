import SwiftData
import SwiftUI

struct NotesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Note.createdAt, order: .reverse) private var notes: [Note]

    @State private var isRecording = false
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "mic",
                        description: Text("Tap Record to capture one, then pick how it gets transcribed.")
                    )
                } else {
                    List {
                        ForEach(notes) { note in
                            NavigationLink(value: note.id) {
                                NoteRow(note: note)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Notes")
            .navigationDestination(for: UUID.self) { id in
                if let note = notes.first(where: { $0.id == id }) {
                    NoteDetailView(note: note)
                } else {
                    ContentUnavailableView("Note not found", systemImage: "questionmark.folder")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        isRecording = true
                    } label: {
                        Label("Record", systemImage: "mic.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
            .fullScreenCover(isPresented: $isRecording) { RecordView() }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let note = notes[index]
            AudioStore.delete(fileNamed: note.audioFileName)
            context.delete(note)
        }
        try? context.save()
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(1)
            if !note.summary.isEmpty {
                Text(note.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                EngineBadge(engine: note.primaryEngine, compact: true)
                Text(note.createdAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text(note.durationSeconds.clockString)
                if note.runs.count > 1 {
                    Text("·")
                    Text("\(note.runs.count) engines")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
