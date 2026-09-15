import Foundation
import OSLog

/// Thin async/await client for the FastAPI backend.
///
/// Built on the main actor from `AppConfig`, then handed to engines that run
/// off it — hence the plain `Sendable` struct.
nonisolated struct BackendClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var timeout: TimeInterval = 300

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    @MainActor
    init(config: AppConfig) throws {
        guard let url = config.resolvedBaseURL, !config.backendAPIKey.isEmpty else {
            throw TranscriptionError.backendNotConfigured
        }
        self.init(baseURL: url, apiKey: config.backendAPIKey)
    }

    // MARK: - Endpoints

    /// `GET /health` — returns a short human-readable summary for Settings.
    func health() async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let payload = try JSONDecoder().decode(HealthResponse.self, from: data)
        return "\(payload.status), asr=\(payload.asrModel), llm=\(payload.llmModel)"
    }

    /// `POST /transcribe` — multipart audio upload.
    func transcribe(audioURL: URL) async throws -> BackendTranscript {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audio = try Data(contentsOf: audioURL)
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendString("\r\n--\(boundary)--\r\n")

        Log.net.info("POST /transcribe \(audio.count / 1024)KB")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try Self.validate(response: response, data: data)
        return try Self.decoder.decode(BackendTranscript.self, from: data)
    }

    /// `POST /enhance` — Claude cleans up a transcript we already have.
    func enhance(transcript: String) async throws -> BackendTranscript {
        var request = URLRequest(url: baseURL.appendingPathComponent("enhance"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EnhanceRequest(transcript: transcript))

        Log.net.info("POST /enhance \(transcript.count) chars")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        return try Self.decoder.decode(BackendTranscript.self, from: data)
    }

    // MARK: - Plumbing

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = errorMessage(from: data)
            Log.net.error("backend \(http.statusCode): \(message, privacy: .public)")
            throw TranscriptionError.backend(status: http.statusCode, message: String(message.prefix(300)))
        }
    }

    /// FastAPI puts the useful part in `{"detail": "…"}`; showing the raw JSON
    /// to the user is just noise.
    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String { return detail }
            // Validation errors come back as a list of objects.
            if let details = object["detail"] as? [[String: Any]] {
                let messages = details.compactMap { $0["msg"] as? String }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
        }
        return String(data: data, encoding: .utf8) ?? "no body"
    }
}

/// Shared shape of `/transcribe` and `/enhance`.
nonisolated struct BackendTranscript: Decodable, Sendable {
    let rawTranscript: String
    let polishedTranscript: String
    let title: String
    let summary: String
    let model: String
    let latencyMs: Int
    /// faster-whisper's segment confidence; `nil` from `/enhance`, which runs no ASR.
    let asrConfidence: Double?
    /// Server-side stage breakdown, so the client can subtract network time.
    let stages: [BackendStage]?
}

nonisolated struct BackendStage: Decodable, Sendable {
    let name: String
    let milliseconds: Int
}

private nonisolated struct HealthResponse: Decodable, Sendable {
    let status: String
    let asrModel: String
    let llmModel: String

    enum CodingKeys: String, CodingKey {
        case status
        case asrModel = "asr_model"
        case llmModel = "llm_model"
    }
}

private nonisolated struct EnhanceRequest: Encodable, Sendable {
    let transcript: String
}

private nonisolated extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
