import Foundation
import Network
import Darwin

/// One document per UUID; atomic replacement avoids partially published snapshots.
struct DeviceUsageSnapshotDirectory: Sendable {
    nonisolated static let maximumSnapshotBytes = 2 * 1024 * 1024
    nonisolated static let maximumDevices = 32
    let url: URL

    nonisolated init(url: URL) { self.url = url.standardizedFileURL }

    nonisolated func write(_ snapshot: DeviceUsageSnapshot) throws {
        try snapshot.validate()
        try self.prepare()
        let existing = try self.read()
        guard existing.contains(where: { $0.deviceID.lowercased() == snapshot.deviceID.lowercased() }) || existing.count < Self.maximumDevices else {
            throw DeviceUsageSyncError.tooManyDevices
        }
        if let previous = existing.first(where: { $0.deviceID.lowercased() == snapshot.deviceID.lowercased() }), previous.generatedAt > snapshot.generatedAt { return }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumSnapshotBytes else { throw DeviceUsageSyncError.oversized }
        let destination = self.url.appendingPathComponent(snapshot.deviceID.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw DeviceUsageSyncError.unsafePath }
        }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    nonisolated func read() throws -> [DeviceUsageSnapshot] {
        try self.prepare()
        let files = try FileManager.default.contentsOfDirectory(at: self.url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard files.count <= Self.maximumDevices else { throw DeviceUsageSyncError.tooManyDevices }
        var records: [DeviceUsageSnapshot] = []
        for file in files {
            // Other devices may be writing/downloading: ignore unavailable snapshots until the next scan.
            guard let data = try? Self.readRegularFile(file, maximumBytes: Self.maximumSnapshotBytes),
                  let record = try? JSONDecoder().decode(DeviceUsageSnapshot.self, from: data),
                  (try? record.validate()) != nil,
                  record.deviceID.lowercased() == file.deletingPathExtension().lastPathComponent.lowercased() else { continue }
            records.append(record)
        }
        return DeviceUsageSnapshot.latestDevices(records)
    }

    nonisolated private func prepare() throws {
        guard self.url.isFileURL, self.url.path != "/" else { throw DeviceUsageSyncError.unsafePath }
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try self.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DeviceUsageSyncError.unsafePath }
    }

    nonisolated static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DeviceUsageSyncError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw DeviceUsageSyncError.unsafePath }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw DeviceUsageSyncError.oversized }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0 else { throw DeviceUsageSyncError.unsafePath }
            guard data.count + count <= maximumBytes else { throw DeviceUsageSyncError.oversized }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}

private final class DeviceUsageNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct DeviceUsageHubClient: Sendable {
    let baseURL: URL
    let secret: String

    nonisolated init(baseURL: URL, secret: String) { self.baseURL = baseURL; self.secret = secret }

    nonisolated static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path == "" || url.path == "/" else { throw DeviceUsageSyncError.invalidConfiguration }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4Literal = labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
        let parts = isIPv4Literal ? labels.compactMap { Int($0) } : []
        let isPrivateIPv4 = parts.count == 4 && parts.allSatisfy({ (0...255).contains($0) }) && (parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])))
        guard url.scheme == "https" || (url.scheme == "http" && (host == "localhost" || host == "::1" || host.hasSuffix(".local") || isPrivateIPv4)) else { throw DeviceUsageSyncError.invalidConfiguration }
        return url
    }

    nonisolated func exchange(_ snapshot: DeviceUsageSnapshot?) async throws -> [DeviceUsageSnapshot] {
        _ = try Self.validatedURL(self.baseURL.absoluteString)
        guard self.secret.count >= 32, !self.secret.contains(where: { $0.isWhitespace }) else { throw DeviceUsageSyncError.invalidConfiguration }
        if let snapshot {
            try snapshot.validate()
            let body = try JSONEncoder().encode(snapshot)
            guard body.count <= DeviceUsageSnapshotDirectory.maximumSnapshotBytes else { throw DeviceUsageSyncError.oversized }
            _ = try await self.request(method: "PUT", path: "v1/snapshot", body: body)
        }
        let data = try await self.request(method: "GET", path: "v1/snapshots", body: nil)
        let records = try JSONDecoder().decode([DeviceUsageSnapshot].self, from: data)
        guard records.count <= DeviceUsageSnapshotDirectory.maximumDevices else { throw DeviceUsageSyncError.tooManyDevices }
        for record in records { try record.validate() }
        return DeviceUsageSnapshot.latestDevices(records)
    }

    nonisolated private func request(method: String, path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("Bearer " + self.secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: DeviceUsageNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DeviceUsageSyncError.connectionFailed }
        if response.statusCode == 401 { throw DeviceUsageSyncError.unauthorized }
        guard response.statusCode == 200 else { throw DeviceUsageSyncError.connectionFailed }
        let limit = DeviceUsageSnapshotDirectory.maximumDevices * DeviceUsageSnapshotDirectory.maximumSnapshotBytes
        guard response.expectedContentLength <= limit else { throw DeviceUsageSyncError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw DeviceUsageSyncError.oversized }
            data.append(byte)
        }
        return data
    }
}

/// Explicitly started only in host mode. A bearer secret is required even on loopback.
final class DeviceUsageHubServer: @unchecked Sendable {
    private let directory: DeviceUsageSnapshotDirectory
    private let secret: String
    private let queue = DispatchQueue(label: "codexbar.device-usage-hub")
    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var connections: [UUID: NWConnection] = [:]

    nonisolated init(directory: DeviceUsageSnapshotDirectory, secret: String) { self.directory = directory; self.secret = secret }

    nonisolated func start(port: UInt16, allowLAN: Bool = false) async throws -> UInt16 {
        guard self.secret.count >= 32 else { throw DeviceUsageSyncError.invalidConfiguration }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: allowLAN ? "0.0.0.0" : "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            self.queue.async { [self] in
                self.listener?.cancel()
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    guard self.connections.count < 16 else { connection.cancel(); return }
                    let id = UUID()
                    self.connections[id] = connection
                    connection.start(queue: self.queue)
                    self.receive(connection, id: id, data: Data())
                    self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.finish(connection, id: id) }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: listener.port?.rawValue ?? port)
                    case .failed:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: DeviceUsageSyncError.connectionFailed)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: DeviceUsageSyncError.connectionFailed)
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    nonisolated func stop() {
        self.queue.async {
            self.listener?.cancel(); self.listener = nil
            self.connections.values.forEach { $0.cancel() }; self.connections.removeAll()
        }
    }

    nonisolated private func finish(_ connection: NWConnection, id: UUID) {
        self.connections.removeValue(forKey: id)
        connection.cancel()
    }

    nonisolated private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { chunk, _, complete, error in
            guard error == nil else { self.finish(connection, id: id); return }
            var data = data
            if let chunk { data.append(chunk) }
            guard data.count <= DeviceUsageSnapshotDirectory.maximumSnapshotBytes + 8192 else { self.respond(connection, id: id, status: 413); return }
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
                guard data.count <= 8192, !complete else { self.respond(connection, id: id, status: 400); return }
                self.receive(connection, id: id, data: data); return
            }
            guard separator.lowerBound <= 8192, let headers = String(data: data[..<separator.lowerBound], encoding: .utf8) else { self.respond(connection, id: id, status: 400); return }
            let lines = headers.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2, fields[pair[0].lowercased()] == nil else { self.respond(connection, id: id, status: 400); return }
                fields[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard request.count == 3, fields["transfer-encoding"] == nil,
                  let length = Int(fields["content-length"] ?? "0"), length >= 0 else { self.respond(connection, id: id, status: 400); return }
            guard length <= DeviceUsageSnapshotDirectory.maximumSnapshotBytes else { self.respond(connection, id: id, status: 413); return }
            guard Self.constantTimeEqual(fields["authorization"] ?? "", "Bearer " + self.secret) else { self.respond(connection, id: id, status: 401); return }
            guard data.count - separator.upperBound >= length else {
                guard !complete else { self.respond(connection, id: id, status: 400); return }
                self.receive(connection, id: id, data: data); return
            }
            do {
                if request[0] == "GET", request[1] == "/v1/snapshots" {
                    self.respond(connection, id: id, status: 200, body: try JSONEncoder().encode(self.directory.read()))
                } else if request[0] == "PUT", request[1] == "/v1/snapshot" {
                    let body = data.subdata(in: separator.upperBound..<(separator.upperBound + length))
                    try self.directory.write(JSONDecoder().decode(DeviceUsageSnapshot.self, from: body))
                    self.respond(connection, id: id, status: 200, body: Data("{}".utf8))
                } else { self.respond(connection, id: id, status: 404) }
            } catch { self.respond(connection, id: id, status: 400) }
        }
    }

    nonisolated private func respond(_ connection: NWConnection, id: UUID, status: Int, body: Data = Data()) {
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in self.finish(connection, id: id) })
    }

    nonisolated private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8), rhs = Array(right.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
