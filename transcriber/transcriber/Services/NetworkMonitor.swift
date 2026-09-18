import Foundation
import Network

/// Coarse "are we online?" check used to decide whether Auto tries the backend.
nonisolated final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.expandlabs.transcriber.network")
    private let lock = NSLock()
    private var _isOnline = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._isOnline = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isOnline
    }
}
