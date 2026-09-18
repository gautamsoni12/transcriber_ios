import Foundation
import OSLog

/// Central logging + stage timing.
///
/// Every transcription path records a `StageTimeline` so the UI (and Console.app)
/// can show where the wall-clock time actually went.
nonisolated enum Log {
    static let subsystem = "com.expandlabs.transcriber"

    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let apple = Logger(subsystem: subsystem, category: "engine.apple")
    static let whisper = Logger(subsystem: subsystem, category: "engine.whisper")
    static let cloud = Logger(subsystem: subsystem, category: "engine.cloud")
    static let auto = Logger(subsystem: subsystem, category: "engine.auto")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let net = Logger(subsystem: subsystem, category: "net")
}

/// One measured stage of a pipeline, e.g. `("model load", 812)`.
nonisolated struct StageTiming: Sendable, Codable, Hashable, Identifiable {
    var name: String
    var milliseconds: Int
    var id: String { name }
}

/// Thread-safe accumulator for stage timings.
///
/// Engines run off the main actor, so this guards its storage with a lock rather
/// than actor isolation (callers await enough already).
nonisolated final class StageTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [StageTiming] = []
    private var cursor = DispatchTime.now()
    private let start = DispatchTime.now()
    private let logger: Logger
    private let label: String

    init(label: String, logger: Logger) {
        self.label = label
        self.logger = logger
    }

    /// Closes out the stage that started when the timeline (or previous stage) ended.
    func mark(_ name: String) {
        let now = DispatchTime.now()
        lock.lock()
        let ms = Int((now.uptimeNanoseconds - cursor.uptimeNanoseconds) / 1_000_000)
        cursor = now
        stages.append(StageTiming(name: name, milliseconds: ms))
        lock.unlock()
        logger.info("[\(self.label, privacy: .public)] stage \(name, privacy: .public) took \(ms)ms")
    }

    /// Total elapsed time since the timeline was created.
    var totalMilliseconds: Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    var snapshot: [StageTiming] {
        lock.lock()
        defer { lock.unlock() }
        return stages
    }

    /// Compact one-line rendering, e.g. `decode 1204ms · polish 880ms`.
    var summary: String {
        snapshot.map { "\($0.name) \($0.milliseconds)ms" }.joined(separator: " · ")
    }

    func finish() -> [StageTiming] {
        let total = totalMilliseconds
        logger.info("[\(self.label, privacy: .public)] total \(total)ms — \(self.summary, privacy: .public)")
        return snapshot
    }
}
