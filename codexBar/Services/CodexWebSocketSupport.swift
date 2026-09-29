import CryptoKit
import Darwin
import Foundation

/// 同步进 Codex `config.toml` 的 `supports_websockets` 指令。
enum CodexWebSocketSupportDirective: Equatable {
    /// 删掉根键，让 Codex 走自己的默认值。用于直连和本地网关，避免把能用的 WebSocket 关掉。
    case remove
    case write(Bool)
}

/// 决定写入 `supports_websockets` 的策略。
///
/// 有远程代理时做真实隧道探测，而不是按 `http` / `socks5` 方案名猜。
/// 一部分 HTTP 代理能完成 WebSocket 所需的 CONNECT，一部分不能。
struct CodexWebSocketSupportCoordinator {
    var now: () -> Date
    var environment: () -> [String: String]
    var systemProxy: () -> OpenAIAccountGatewaySystemProxySnapshot?
    var cache: CodexWebSocketProbeCache
    var probe: (OpenAIAccountGatewayConfiguredProxy, CodexWebSocketDestination) -> Bool

    static let live = CodexWebSocketSupportCoordinator(
        now: Date.init,
        environment: { ProcessInfo.processInfo.environment },
        systemProxy: { OpenAIAccountGatewaySystemProxySnapshot.captureCurrent() },
        cache: .shared,
        probe: { proxy, destination in
            CodexWebSocketProxyProbe.supportsWebSocketTunnel(
                through: proxy,
                destinationHost: destination.host,
                destinationPort: destination.port
            )
        }
    )

    func directive(for config: CodexBarConfig, route: ResolvedCodexRoute) -> CodexWebSocketSupportDirective {
        switch config.openAI.webSocketSupportOverride {
        case .enabled:
            return .write(true)
        case .disabled:
            return .write(false)
        case .automatic:
            break
        }

        guard let destination = CodexWebSocketDestinationResolver.destination(for: route),
              let proxy = CodexEffectiveProxyResolver.proxy(
                for: destination,
                environment: self.environment(),
                systemProxy: self.systemProxy()
              ) else {
            return .remove
        }

        let key = CodexWebSocketProbeCache.Key(proxy: proxy, destination: destination)
        let now = self.now()
        if let cached = self.cache.value(for: key, now: now) {
            return .write(cached)
        }
        let supported = self.probe(proxy, destination)
        self.cache.store(supported, for: key, at: now)
        return .write(supported)
    }
}

struct CodexWebSocketDestination: Equatable {
    var host: String
    var port: Int
    var usesTLS: Bool
}

enum CodexWebSocketDestinationResolver {
    /// 本地网关自己实现了 WebSocket upgrade。Codex 连到环回地址时不按上游代理把开关写成 false。
    static func destination(for route: ResolvedCodexRoute) -> CodexWebSocketDestination? {
        if route.routesOpenAITargetThroughGateway {
            return nil
        }
        switch route.targetProvider.kind {
        case .openAIOAuth:
            return CodexWebSocketDestination(host: "chatgpt.com", port: 443, usesTLS: true)
        case .openRouter:
            return nil
        case .openAICompatible:
            if route.targetProvider.usesChatCompletionsGateway {
                return nil
            }
            return self.remoteDestination(from: route.targetProvider.baseURL)
        }
    }

    private static func remoteDestination(from baseURL: String?) -> CodexWebSocketDestination? {
        guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false,
              let components = URLComponents(string: raw),
              let host = components.host,
              host.isEmpty == false,
              self.isLoopback(host) == false else {
            return nil
        }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard scheme == "http" || scheme == "https" else { return nil }
        let usesTLS = scheme == "https"
        let port = components.port ?? (usesTLS ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        return CodexWebSocketDestination(host: host, port: port, usesTLS: usesTLS)
    }

    static func isLoopback(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized.hasSuffix(".localhost")
    }
}

enum CodexEffectiveProxyResolver {
    /// Codex 访问远程 API 时实际会用到的代理。环境变量优先于系统代理；例外名单命中则视为直连。
    static func proxy(
        for destination: CodexWebSocketDestination,
        environment: [String: String],
        systemProxy: OpenAIAccountGatewaySystemProxySnapshot?
    ) -> OpenAIAccountGatewayConfiguredProxy? {
        if let environmentProxy = self.environmentProxy(for: destination, environment: environment) {
            if self.noProxyMatches(destination.host, environment: environment) {
                return nil
            }
            return environmentProxy
        }
        guard let systemProxy,
              self.isSystemBypassed(destination.host, snapshot: systemProxy) == false else {
            return nil
        }
        return self.proxy(from: systemProxy, usesTLS: destination.usesTLS)
    }

    private static func environmentProxy(
        for destination: CodexWebSocketDestination,
        environment: [String: String]
    ) -> OpenAIAccountGatewayConfiguredProxy? {
        let keys = destination.usesTLS
            ? ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"]
            : ["http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"]
        for key in keys {
            guard let proxy = OpenAIAccountGatewayConfiguredProxy(address: self.unquoted(environment[key])) else {
                continue
            }
            return proxy
        }
        return nil
    }

    private static func proxy(
        from snapshot: OpenAIAccountGatewaySystemProxySnapshot,
        usesTLS: Bool
    ) -> OpenAIAccountGatewayConfiguredProxy? {
        let ordered: [OpenAIAccountGatewaySystemProxyEndpoint?] = usesTLS
            ? [snapshot.https, snapshot.socks, snapshot.http]
            : [snapshot.http, snapshot.socks, snapshot.https]
        for endpoint in ordered {
            guard let endpoint else { continue }
            let kind: OpenAIAccountGatewayConfiguredProxy.Kind = endpoint.kind == "socks" ? .socks : .http
            if let proxy = OpenAIAccountGatewayConfiguredProxy(kind: kind, host: endpoint.host, port: endpoint.port) {
                return proxy
            }
        }
        return nil
    }

    private static func noProxyMatches(_ host: String, environment: [String: String]) -> Bool {
        let raw = [environment["NO_PROXY"], environment["no_proxy"]]
            .compactMap { $0 }
            .joined(separator: ",")
        let patterns = raw.split { $0 == "," || $0.isWhitespace }.map(String.init)
        return self.hostMatches(host, patterns: patterns)
    }

    private static func isSystemBypassed(
        _ host: String,
        snapshot: OpenAIAccountGatewaySystemProxySnapshot
    ) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if snapshot.excludesSimpleHostnames,
           normalized.contains(".") == false,
           normalized.contains(":") == false {
            return true
        }
        return self.hostMatches(host, patterns: snapshot.exceptions)
    }

    static func hostMatches(_ host: String, patterns: [String]) -> Bool {
        let host = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }
            if pattern == "*" || pattern == host { return true }
            if pattern.hasPrefix("*."), host.hasSuffix(pattern.dropFirst()) {
                return true
            }
            if pattern.hasPrefix("."), host.hasSuffix(pattern), host.count > pattern.count {
                return true
            }
        }
        return false
    }

    private static func unquoted(_ value: String?) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

final class CodexWebSocketProbeCache {
    static let defaultTTL: TimeInterval = 10 * 60
    static let shared = CodexWebSocketProbeCache(
        ttl: CodexWebSocketProbeCache.defaultTTL,
        storageURLProvider: { CodexPaths.webSocketProbeCacheURL }
    )

    struct Key: Hashable {
        let proxy: OpenAIAccountGatewayConfiguredProxy
        let destinationHost: String
        let destinationPort: Int

        init(proxy: OpenAIAccountGatewayConfiguredProxy, destination: CodexWebSocketDestination) {
            self.proxy = proxy
            self.destinationHost = destination.host.lowercased()
            self.destinationPort = destination.port
        }

        init(proxy: OpenAIAccountGatewayConfiguredProxy, destinationHost: String, destinationPort: Int) {
            self.proxy = proxy
            self.destinationHost = destinationHost.lowercased()
            self.destinationPort = destinationPort
        }

        /// 含代理口令的指纹。磁盘上只保存哈希，避免把凭据写进缓存文件。
        var fingerprint: String {
            let material = [
                self.proxy.kind.rawValue,
                self.proxy.host.lowercased(),
                String(self.proxy.port),
                self.proxy.username ?? "",
                self.proxy.password ?? "",
                self.destinationHost,
                String(self.destinationPort),
            ].joined(separator: "\n")
            let digest = SHA256.hash(data: Data(material.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct Stored {
        var supportsWebSockets: Bool
        var probedAt: Date
    }

    private struct DiskFile: Codable {
        struct Item: Codable {
            var fingerprint: String
            var supportsWebSockets: Bool
            var probedAt: TimeInterval
        }

        var items: [Item]
    }

    private let lock = NSLock()
    private var memory: [String: Stored] = [:]
    private var didLoad = false
    let ttl: TimeInterval
    private let storageURL: URL?
    private let storageURLProvider: (() -> URL)?

    init(
        ttl: TimeInterval = CodexWebSocketProbeCache.defaultTTL,
        storageURL: URL? = nil,
        storageURLProvider: (() -> URL)? = nil
    ) {
        self.ttl = ttl
        self.storageURL = storageURL
        self.storageURLProvider = storageURLProvider
    }

    func value(for key: Key, now: Date) -> Bool? {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadLocked()
        guard let stored = self.memory[key.fingerprint] else { return nil }
        guard now.timeIntervalSince(stored.probedAt) < self.ttl else {
            self.memory.removeValue(forKey: key.fingerprint)
            self.persistLocked(now: now)
            return nil
        }
        return stored.supportsWebSockets
    }

    func store(_ supportsWebSockets: Bool, for key: Key, at date: Date) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.loadLocked()
        self.memory[key.fingerprint] = Stored(supportsWebSockets: supportsWebSockets, probedAt: date)
        self.persistLocked(now: date)
    }

    private func resolvedStorageURL() -> URL? {
        self.storageURL ?? self.storageURLProvider?()
    }

    private func loadLocked() {
        guard self.didLoad == false else { return }
        self.didLoad = true
        guard let url = self.resolvedStorageURL(),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(DiskFile.self, from: data) else {
            return
        }
        for item in file.items {
            self.memory[item.fingerprint] = Stored(
                supportsWebSockets: item.supportsWebSockets,
                probedAt: Date(timeIntervalSince1970: item.probedAt)
            )
        }
    }

    private func persistLocked(now: Date) {
        guard let url = self.resolvedStorageURL() else { return }
        self.memory = self.memory.filter { now.timeIntervalSince($0.value.probedAt) < self.ttl }
        let file = DiskFile(items: self.memory.map { fingerprint, stored in
            DiskFile.Item(
                fingerprint: fingerprint,
                supportsWebSockets: stored.supportsWebSockets,
                probedAt: stored.probedAt.timeIntervalSince1970
            )
        })
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? CodexPaths.writeSecureFile(data, to: url)
    }
}

enum CodexWebSocketProxyProbe {
    static let defaultTimeout: TimeInterval = 2

    /// 探测代理能否承载 Codex 的 `wss://`。
    /// HTTP 代理看 CONNECT 是否建立隧道，SOCKS5 看 CONNECT 应答。
    /// 成功与否不按方案名推断：有的 HTTP 代理支持 WebSocket CONNECT，有的不支持。
    static func supportsWebSocketTunnel(
        through proxy: OpenAIAccountGatewayConfiguredProxy,
        destinationHost: String,
        destinationPort: Int,
        timeout: TimeInterval = CodexWebSocketProxyProbe.defaultTimeout
    ) -> Bool {
        guard (1...65535).contains(proxy.port),
              (1...65535).contains(destinationPort),
              destinationHost.isEmpty == false,
              destinationHost.contains("\r") == false,
              destinationHost.contains("\n") == false,
              proxy.username?.contains("\r") != true,
              proxy.username?.contains("\n") != true,
              proxy.password?.contains("\r") != true,
              proxy.password?.contains("\n") != true else {
            return false
        }
        guard let fd = self.connectTCP(host: proxy.host, port: proxy.port, timeout: timeout) else {
            self.logUnsupported(proxy)
            return false
        }
        defer { Darwin.close(fd) }
        let supported: Bool
        switch proxy.kind {
        case .http:
            supported = self.probeHTTPConnect(
                fd: fd,
                proxy: proxy,
                destinationHost: destinationHost,
                destinationPort: destinationPort
            )
        case .socks:
            supported = self.probeSOCKS5(
                fd: fd,
                proxy: proxy,
                destinationHost: destinationHost,
                destinationPort: destinationPort
            )
        }
        if supported == false {
            self.logUnsupported(proxy)
        }
        return supported
    }

    private static func logUnsupported(_ proxy: OpenAIAccountGatewayConfiguredProxy) {
        NSLog(
            "codexbar websocket probe unsupported via %@:%d (%@)",
            proxy.host,
            proxy.port,
            proxy.kind.rawValue
        )
    }

    private static func probeHTTPConnect(
        fd: Int32,
        proxy: OpenAIAccountGatewayConfiguredProxy,
        destinationHost: String,
        destinationPort: Int
    ) -> Bool {
        let authority = self.connectAuthority(host: destinationHost, port: destinationPort)
        var lines = [
            "CONNECT \(authority) HTTP/1.1",
            "Host: \(authority)",
        ]
        if let username = proxy.username {
            let token = Data("\(username):\(proxy.password ?? "")".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(token)")
        }
        let payload = lines.joined(separator: "\r\n") + "\r\n\r\n"
        guard self.writeAll(fd: fd, data: Data(payload.utf8)),
              let statusLine = self.readUntilNewline(fd: fd) else {
            return false
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return false }
        return (200..<300).contains(code)
    }

    private static func probeSOCKS5(
        fd: Int32,
        proxy: OpenAIAccountGatewayConfiguredProxy,
        destinationHost: String,
        destinationPort: Int
    ) -> Bool {
        let hostBytes = Array(destinationHost.utf8)
        guard (1...255).contains(hostBytes.count) else { return false }

        var greeting = Data([0x05])
        if proxy.username == nil {
            greeting.append(contentsOf: [0x01, 0x00])
        } else {
            greeting.append(contentsOf: [0x02, 0x00, 0x02])
        }
        guard self.writeAll(fd: fd, data: greeting),
              let methodReply = self.readExact(fd: fd, count: 2),
              methodReply[0] == 0x05 else {
            return false
        }
        switch methodReply[1] {
        case 0x00:
            break
        case 0x02:
            guard let username = proxy.username,
                  self.authenticateSOCKS(fd: fd, username: username, password: proxy.password ?? "") else {
                return false
            }
        default:
            return false
        }

        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
        request.append(contentsOf: hostBytes)
        request.append(UInt8((destinationPort >> 8) & 0xFF))
        request.append(UInt8(destinationPort & 0xFF))
        guard self.writeAll(fd: fd, data: request),
              let reply = self.readExact(fd: fd, count: 4) else {
            return false
        }
        return reply[0] == 0x05 && reply[1] == 0x00
    }

    private static func authenticateSOCKS(fd: Int32, username: String, password: String) -> Bool {
        let user = Array(username.utf8.prefix(255))
        let pass = Array(password.utf8.prefix(255))
        guard user.isEmpty == false else { return false }
        var request = Data([0x01, UInt8(user.count)])
        request.append(contentsOf: user)
        request.append(UInt8(pass.count))
        request.append(contentsOf: pass)
        guard self.writeAll(fd: fd, data: request),
              let reply = self.readExact(fd: fd, count: 2) else {
            return false
        }
        return reply[0] == 0x01 && reply[1] == 0x00
    }

    private static func connectAuthority(host: String, port: Int) -> String {
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    private static func connectTCP(host: String, port: Int, timeout: TimeInterval) -> Int32? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let resolution = host.withCString { hostPointer in
            String(port).withCString { portPointer in
                Darwin.getaddrinfo(hostPointer, portPointer, &hints, &info)
            }
        }
        guard resolution == 0, let info else { return nil }
        defer { Darwin.freeaddrinfo(info) }

        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let current = cursor {
            let fd = Darwin.socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                if self.finishConnect(fd, to: current, timeout: timeout) {
                    return fd
                }
                Darwin.close(fd)
            }
            cursor = current.pointee.ai_next
        }
        return nil
    }

    private static func finishConnect(
        _ fd: Int32,
        to info: UnsafeMutablePointer<addrinfo>,
        timeout: TimeInterval
    ) -> Bool {
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        guard Darwin.fcntl(fd, F_SETFL, flags | Int32(O_NONBLOCK)) >= 0 else { return false }
        let result = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if result < 0 && errno != EINPROGRESS {
            return false
        }
        if result < 0 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(1, min(timeout, 60)) * 1000)
            let polled = Darwin.poll(&descriptor, nfds_t(1), milliseconds)
            guard polled > 0 else { return false }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            let status = Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard status == 0, socketError == 0 else { return false }
        }
        guard Darwin.fcntl(fd, F_SETFL, flags) >= 0 else { return false }
        self.setTimeout(fd, timeout)
        return true
    }

    private static func setTimeout(_ fd: Int32, _ timeout: TimeInterval) {
        let whole = time_t(max(0, timeout))
        let microseconds = Int((max(0, timeout - Double(whole)) * 1_000_000).rounded())
        var value = timeval(
            tv_sec: whole,
            tv_usec: suseconds_t(microseconds)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < data.count {
                let count = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if count > 0 {
                    sent += count
                } else if errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func readExact(fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let countRead = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), count - offset)
            }
            if countRead > 0 {
                offset += countRead
            } else if countRead == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return data
    }

    private static func readUntilNewline(fd: Int32, limit: Int = 1024) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count < limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if let newline = data.firstIndex(of: 0x0A) {
                    let line = data.prefix(upTo: newline).filter { $0 != 0x0D }
                    return String(bytes: line, encoding: .utf8)
                }
            } else if count == 0 {
                return nil
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
    }
}
