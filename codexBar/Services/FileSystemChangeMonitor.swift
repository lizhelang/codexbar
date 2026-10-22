import CoreServices
import Foundation

/// Counts FSEvents under a set of directories so periodic scans can be skipped while nothing changed.
/// It only answers "did anything change"; consumers still rescan on their own schedule, and a
/// safety window elsewhere covers missed events (unmounted volumes, roots created after start).
nonisolated final class FileSystemChangeMonitor: @unchecked Sendable {
    let watchedPaths: [String]

    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "lzl.codexbar.fs-change-monitor", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var changeCount: UInt64 = 0

    /// Missing roots are replaced by their nearest existing parent below the home directory, so a
    /// tool installed later is still noticed; roots with no such parent are left to the safety window.
    init(roots: [URL], latency: CFTimeInterval = 3) {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var paths: [String] = []
        for root in roots {
            var candidate = root.standardizedFileURL
            while true {
                let path = candidate.path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    if path != home, path != "/", !paths.contains(path) { paths.append(path) }
                    break
                }
                let parent = candidate.deletingLastPathComponent()
                guard parent.path != path, parent.path.hasPrefix(home), parent.path != home else { break }
                candidate = parent
            }
        }
        self.watchedPaths = paths.sorted()
        self.latency = latency
    }

    deinit {
        self.stop()
    }

    /// Monotonic count of event batches since `start()`. Compare with a remembered value to detect changes.
    var currentChangeCount: UInt64 {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.changeCount
    }

    var isRunning: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stream != nil
    }

    @discardableResult
    func start() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.stream == nil else { return true }
        guard !self.watchedPaths.isEmpty else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileSystemChangeMonitor>.fromOpaque(info).takeUnretainedValue().noteChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            self.watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            self.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, self.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        self.lock.lock()
        let stream = self.stream
        self.stream = nil
        self.lock.unlock()
        guard let stream else { return }
        // Tear down on the callback queue so no callback can still be using `self` afterwards.
        self.queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func noteChange() {
        self.lock.lock()
        self.changeCount &+= 1
        self.lock.unlock()
    }
}

/// Decides whether a periodic local scan is worth running: always when no monitor could start,
/// otherwise only after a file event or once `maximumAge` has passed since the last scan.
nonisolated struct LocalScanGate {
    private(set) var monitor: FileSystemChangeMonitor?
    private var scannedChangeCount: UInt64?
    private var lastScanUptime: TimeInterval?

    /// Rebuilds the monitor when the watched roots change. Returns true if they did.
    @discardableResult
    mutating func watch(_ roots: [URL]) -> Bool {
        let next = FileSystemChangeMonitor(roots: roots)
        if let monitor, monitor.watchedPaths == next.watchedPaths, monitor.isRunning { return false }
        self.monitor?.stop()
        self.monitor = next.start() ? next : nil
        self.scannedChangeCount = nil
        return true
    }

    func shouldScan(maximumAge: TimeInterval, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let monitor, let scannedChangeCount, let lastScanUptime else { return true }
        return monitor.currentChangeCount != scannedChangeCount || uptime - lastScanUptime >= maximumAge
    }

    /// Call when a scan starts: events that arrive while it runs keep the next scan due.
    mutating func markScanStarted(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.scannedChangeCount = self.monitor?.currentChangeCount
        self.lastScanUptime = uptime
    }
}
