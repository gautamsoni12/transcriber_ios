import AVFoundation
import Foundation

/// Where recordings live on disk, plus small helpers over them.
nonisolated enum AudioStore {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static func newRecordingURL() -> URL {
        let stamp = Self.filenameFormatter.string(from: Date())
        return documentsDirectory.appendingPathComponent("recording-\(stamp).wav")
    }

    static func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func delete(fileNamed name: String) {
        guard !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent(name))
    }

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
