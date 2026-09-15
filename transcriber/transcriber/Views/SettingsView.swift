import SwiftUI

/// Backend endpoint, API key and the Whisper model toggle.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = AppConfig.shared
    @State private var healthMessage: String?
    @State private var isCheckingHealth = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-service.run.app", text: $config.backendBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key", text: $config.backendAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Backend")
                } footer: {
                    Text("Used by the Cloud and Auto modes. The key is stored in the Keychain; the URL in user defaults. Neither is compiled into the app.")
                }

                Section {
                    Button {
                        Task { await checkHealth() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if isCheckingHealth { ProgressView() }
                        }
                    }
                    .disabled(isCheckingHealth || !config.isBackendConfigured)

                    if let healthMessage {
                        Text(healthMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Whisper model", selection: $config.whisperModelVariant) {
                        ForEach(WhisperModelVariant.allCases) { variant in
                            Text(variant.displayName).tag(variant.rawValue)
                        }
                    }
                } header: {
                    Text("Local (Whisper)")
                } footer: {
                    Text("Switching models downloads the new one on its next use. Models live in Application Support and are never uploaded.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func checkHealth() async {
        isCheckingHealth = true
        healthMessage = nil
        defer { isCheckingHealth = false }
        do {
            let client = try BackendClient(config: config)
            let info = try await client.health()
            healthMessage = "OK — \(info)"
        } catch {
            healthMessage = error.localizedDescription
        }
    }
}
