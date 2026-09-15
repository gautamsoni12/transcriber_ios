import AVFoundation
import Foundation
import OSLog

/// Receives tap buffers on the audio render thread and writes 16 kHz mono PCM.
///
/// The mic hands us whatever the hardware runs at (usually 44.1/48 kHz stereo);
/// this converts to the 16 kHz mono that both Whisper and `SpeechAnalyzer` want,
/// and writes a plain 16-bit WAV so the backend can accept the same file.
nonisolated final class RecordingSink: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var _level: Double = 0
    private var _frameCount: AVAudioFramePosition = 0

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.audioUnreadable("could not build a 16 kHz mono format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionError.audioUnreadable("no converter from \(inputFormat) to 16 kHz mono")
        }

        // Settings describe the on-disk file (Int16 WAV); commonFormat describes
        // the buffers we hand to `write(from:)`.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// Called from the engine's tap thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block is called synchronously by `convert`, so handing the
        // tap's buffer straight through is safe despite the @Sendable signature.
        nonisolated(unsafe) let source = buffer
        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return source
        }

        guard status != .error, output.frameLength > 0 else {
            if let conversionError {
                Log.recording.error("convert failed: \(conversionError.localizedDescription, privacy: .public)")
            }
            return
        }

        do {
            try file.write(from: output)
        } catch {
            Log.recording.error("write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let level = Self.normalizedLevel(of: output)
        lock.lock()
        _level = level
        _frameCount += AVAudioFramePosition(output.frameLength)
        lock.unlock()
    }

    /// 0…1 meter value for the UI.
    var level: Double {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(_frameCount) / Self.targetSampleRate
    }

    private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += channel[i] * channel[i]
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        // Map -60…0 dBFS onto 0…1.
        return Double(max(0, min(1, (db + 60) / 60)))
    }
}
