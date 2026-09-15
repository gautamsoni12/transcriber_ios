import AVFoundation
import Foundation
import Observation
import OSLog

/// Mic capture via `AVAudioEngine`, writing 16 kHz mono WAV into Documents.
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var level: Double = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var sink: RecordingSink?
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Asks for mic access; returns false if the user has denied it.
    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start() throws -> URL {
        guard !isRecording else { throw TranscriptionError.audioUnreadable("already recording") }
        errorMessage = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: [])

        let url = AudioStore.newRecordingURL()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        Log.recording.info("mic format \(inputFormat.sampleRate, privacy: .public)Hz x\(inputFormat.channelCount, privacy: .public)ch → 16000Hz mono")

        let sink = try RecordingSink(url: url, inputFormat: inputFormat)
        self.sink = sink
        self.currentURL = url

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            sink.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        startTicking()
        Log.recording.info("recording started → \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// Stops the engine and returns the finished file, or `nil` if nothing usable was captured.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ticker?.cancel()
        ticker = nil
        isRecording = false
        level = 0

        let url = currentURL
        let captured = sink?.duration ?? 0
        sink = nil
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        Log.recording.info("recording stopped after \(captured, format: .fixed(precision: 2), privacy: .public)s")

        guard let url, captured > 0.2 else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return url
    }

    func cancel() {
        let url = currentURL
        stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        elapsed = 0
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let sink = self.sink else { return }
                self.level = sink.level
                self.elapsed = sink.duration
            }
        }
    }
}
