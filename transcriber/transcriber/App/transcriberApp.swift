//
//  transcriberApp.swift
//  transcriber
//

import SwiftData
import SwiftUI

@main
struct transcriberApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Note.self, EngineRun.self)
        } catch {
            fatalError("Could not open the notes store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            NotesListView()
                #if DEBUG
                .task { _ = SelfTest.runIfRequested() }
                #endif
        }
        .modelContainer(container)
    }
}
