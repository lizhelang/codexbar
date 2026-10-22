import Foundation

/// Identity of a file's current contents for parse caching: same inode, size and modification time.
nonisolated struct FileStamp: Equatable, Sendable {
    let fileNumber: UInt64
    let size: Int64
    let modificationDate: Date

    static func of(path: String) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileStamp(
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date ?? .distantPast
        )
    }
}

/// Remembers what a collector parsed out of each file so periodic scans only re-read files that changed.
/// Values must be pure functions of the file contents; anything that depends on `now` is applied after lookup.
nonisolated final class FileParseCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: FileStamp, value: Value)] = [:]

    func value(for path: String, stamp: FileStamp) -> Value? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entries[path], entry.stamp == stamp else { return nil }
        return entry.value
    }

    func store(_ value: Value, for path: String, stamp: FileStamp) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[path] = (stamp, value)
    }

    /// Returns the cached value when the file is unchanged, otherwise parses it and caches the result.
    func value(for path: String, parse: () throws -> Value) rethrows -> Value {
        guard let stamp = FileStamp.of(path: path) else { return try parse() }
        if let cached = self.value(for: path, stamp: stamp) { return cached }
        let value = try parse()
        self.store(value, for: path, stamp: stamp)
        return value
    }

    /// Drops entries under `roots` that were not seen in the latest scan, so deleted files do not linger.
    func retainOnly(_ seenPaths: Set<String>, under roots: [URL]) {
        let prefixes = roots.map { $0.standardizedFileURL.path + "/" }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries = self.entries.filter { path, _ in
            seenPaths.contains(path) || !prefixes.contains { path.hasPrefix($0) }
        }
    }
}
