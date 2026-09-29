import CFNetwork
import Darwin
import XCTest

final class CodexWebSocketSupportTests: CodexBarTestCase {
    func testSynchronizeUpsertsSupportsWebSocketsAndPreservesTableKeys() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(
            Data(
                """
                supports_websockets = true
                model = "gpt-5.5"

                [profiles.personal]
                supports_websockets = true
                model = "keep-profile-model"
                """.utf8
            ),
            to: CodexPaths.configTomlURL
        )

        let service = CodexSyncService(webSocketSupportDirective: { _, _ in .write(false) })
        try service.synchronize(config: self.oauthConfig())

        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        let root = String(tomlText.prefix { $0 != "[" })
        XCTAssertTrue(root.contains("supports_websockets = false"))
        XCTAssertFalse(root.contains("supports_websockets = true"))
        XCTAssertEqual(root.components(separatedBy: "supports_websockets").count, 2)
        XCTAssertTrue(tomlText.contains("[profiles.personal]\nsupports_websockets = true"))

        let clearing = CodexSyncService(webSocketSupportDirective: { _, _ in .remove })
        try clearing.synchronize(config: self.oauthConfig())
        let cleared = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        let clearedRoot = String(cleared.prefix { $0 != "[" })
        XCTAssertFalse(clearedRoot.contains("supports_websockets"))
        XCTAssertTrue(cleared.contains("[profiles.personal]\nsupports_websockets = true"))
    }

    func testProbeResultMapsToSupportsWebSocketsWithoutUsingSchemeHeuristic() throws {
        let route = try CodexRouteResolver.resolve(config: self.oauthConfig())
        var probedKind: OpenAIAccountGatewayConfiguredProxy.Kind?
        let coordinator = self.coordinator(
            environment: { ["https_proxy": "http://127.0.0.1:7890"] },
            probe: { proxy, _ in
                probedKind = proxy.kind
                return true
            }
        )

        XCTAssertEqual(coordinator.directive(for: self.oauthConfig(), route: route), .write(true))
        XCTAssertEqual(probedKind, .http)

        let failing = self.coordinator(
            environment: { ["https_proxy": "http://127.0.0.1:7890"] },
            probe: { _, _ in false }
        )
        XCTAssertEqual(failing.directive(for: self.oauthConfig(), route: route), .write(false))
    }

    func testOverrideSkipsProbe() throws {
        let route = try CodexRouteResolver.resolve(config: self.oauthConfig())
        var probes = 0
        let coordinator = self.coordinator(
            environment: { ["https_proxy": "socks5://127.0.0.1:1080"] },
            probe: { _, _ in
                probes += 1
                return true
            }
        )

        var enabled = self.oauthConfig()
        enabled.openAI.webSocketSupportOverride = .enabled
        XCTAssertEqual(coordinator.directive(for: enabled, route: route), .write(true))

        var disabled = self.oauthConfig()
        disabled.openAI.webSocketSupportOverride = .disabled
        XCTAssertEqual(coordinator.directive(for: disabled, route: route), .write(false))
        XCTAssertEqual(probes, 0)
    }

    func testDirectAndLocalGatewayPathsDoNotForceWebSocketsOff() throws {
        var probes = 0
        let coordinator = self.coordinator(
            environment: { ["https_proxy": "http://127.0.0.1:7890"] },
            probe: { _, _ in
                probes += 1
                return false
            }
        )

        let direct = self.coordinator(environment: { [:] }, probe: { _, _ in
            probes += 1
            return false
        })
        let directRoute = try CodexRouteResolver.resolve(config: self.oauthConfig())
        XCTAssertEqual(direct.directive(for: self.oauthConfig(), route: directRoute), .remove)

        var aggregate = self.oauthConfig()
        aggregate.openAI.accountUsageMode = .aggregateGateway
        let aggregateRoute = try CodexRouteResolver.resolve(config: aggregate)
        XCTAssertEqual(coordinator.directive(for: aggregate, route: aggregateRoute), .remove)

        let loopbackRoute = try CodexRouteResolver.resolve(config: self.compatibleConfig(baseURL: "http://127.0.0.1:9/v1"))
        XCTAssertEqual(coordinator.directive(for: self.compatibleConfig(baseURL: "http://127.0.0.1:9/v1"), route: loopbackRoute), .remove)
        XCTAssertEqual(probes, 0)
    }

    func testProbeCacheInvalidatesWhenProxyChangesOrExpires() throws {
        var environment = ["https_proxy": "http://127.0.0.1:7890"]
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var probes = 0
        let coordinator = CodexWebSocketSupportCoordinator(
            now: { now },
            environment: { environment },
            systemProxy: { nil },
            cache: CodexWebSocketProbeCache(ttl: 600),
            probe: { _, _ in
                probes += 1
                return false
            }
        )
        let config = self.oauthConfig()
        let route = try CodexRouteResolver.resolve(config: config)

        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))
        XCTAssertEqual(probes, 1)

        environment = ["https_proxy": "http://user:one@127.0.0.1:7890"]
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))
        environment = ["https_proxy": "http://user:two@127.0.0.1:7890"]
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))
        environment = ["https_proxy": "http://127.0.0.1:7891"]
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))
        XCTAssertEqual(probes, 4)

        now = now.addingTimeInterval(601)
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))
        XCTAssertEqual(probes, 5)
    }

    func testProbeCacheRoundTripsUntilProxyOrTTLChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("websocket-probe-cache.json")
        let proxy = try XCTUnwrap(OpenAIAccountGatewayConfiguredProxy(address: "http://user:s3cret@127.0.0.1:7890"))
        let other = try XCTUnwrap(OpenAIAccountGatewayConfiguredProxy(address: "socks5://127.0.0.1:1080"))
        let key = CodexWebSocketProbeCache.Key(proxy: proxy, destinationHost: "chatgpt.com", destinationPort: 443)
        let otherKey = CodexWebSocketProbeCache.Key(proxy: other, destinationHost: "chatgpt.com", destinationPort: 443)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let cache = CodexWebSocketProbeCache(ttl: 600, storageURL: url)
        XCTAssertNil(cache.value(for: key, now: start))
        cache.store(false, for: key, at: start)

        let reloaded = CodexWebSocketProbeCache(ttl: 600, storageURL: url)
        XCTAssertEqual(reloaded.value(for: key, now: start.addingTimeInterval(30)), false)
        XCTAssertNil(reloaded.value(for: otherKey, now: start.addingTimeInterval(30)))
        XCTAssertNil(reloaded.value(for: key, now: start.addingTimeInterval(601)))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("127.0.0.1"))
        XCTAssertFalse(text.contains("s3cret"))
    }

    func testEffectiveProxyPrefersEnvironmentAndHonorsBypassLists() throws {
        let destination = CodexWebSocketDestination(host: "chatgpt.com", port: 443, usesTLS: true)
        let system = OpenAIAccountGatewaySystemProxySnapshot(
            http: nil,
            https: OpenAIAccountGatewaySystemProxyEndpoint(kind: "https", host: "10.0.0.8", port: 7897),
            socks: OpenAIAccountGatewaySystemProxyEndpoint(kind: "socks", host: "10.0.0.8", port: 1080)
        )

        let fromEnvironment = CodexEffectiveProxyResolver.proxy(
            for: destination,
            environment: ["all_proxy": "socks5://127.0.0.1:1080", "NO_PROXY": "localhost"],
            systemProxy: system
        )
        XCTAssertEqual(fromEnvironment?.kind, .socks)
        XCTAssertEqual(fromEnvironment?.port, 1080)

        XCTAssertNil(
            CodexEffectiveProxyResolver.proxy(
                for: destination,
                environment: ["https_proxy": "http://127.0.0.1:7890", "no_proxy": "*"],
                systemProxy: system
            )
        )

        let fromSystem = CodexEffectiveProxyResolver.proxy(
            for: destination,
            environment: [:],
            systemProxy: system
        )
        XCTAssertEqual(fromSystem?.kind, .http)
        XCTAssertEqual(fromSystem?.host, "10.0.0.8")
        XCTAssertEqual(fromSystem?.port, 7897)

        let bypassed = OpenAIAccountGatewaySystemProxySnapshot(
            http: nil,
            https: system.https,
            socks: nil,
            exceptions: ["*.chatgpt.com", "chatgpt.com"]
        )
        XCTAssertNil(
            CodexEffectiveProxyResolver.proxy(
                for: destination,
                environment: [:],
                systemProxy: bypassed
            )
        )

        let simple = OpenAIAccountGatewaySystemProxySnapshot(
            http: OpenAIAccountGatewaySystemProxyEndpoint(kind: "http", host: "10.0.0.8", port: 7890),
            https: nil,
            socks: nil,
            excludesSimpleHostnames: true
        )
        XCTAssertNil(
            CodexEffectiveProxyResolver.proxy(
                for: CodexWebSocketDestination(host: "intranet", port: 80, usesTLS: false),
                environment: [:],
                systemProxy: simple
            )
        )
    }

    func testSystemProxySnapshotKeepsExceptionList() {
        let snapshot = OpenAIAccountGatewaySystemProxySnapshot(settings: [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: 7890,
            kCFNetworkProxiesExceptionsList as String: ["localhost", "chatgpt.com"],
            kCFNetworkProxiesExcludeSimpleHostnames as String: 1,
        ])
        XCTAssertEqual(snapshot?.exceptions, ["localhost", "chatgpt.com"])
        XCTAssertTrue(snapshot?.excludesSimpleHostnames == true)
        XCTAssertEqual(
            OpenAIAccountGatewayConfiguredProxy(address: "socks5h://127.0.0.1:7891")?.kind,
            .socks
        )
    }

    func testWebSocketOverrideDecodesAndSaves() throws {
        let missing = try JSONDecoder().decode(CodexBarOpenAISettings.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.webSocketSupportOverride, .automatic)
        let decoded = try JSONDecoder().decode(
            CodexBarOpenAISettings.self,
            from: Data(#"{"webSocketSupportOverride":"enabled"}"#.utf8)
        )
        XCTAssertEqual(decoded.webSocketSupportOverride, .enabled)

        var config = CodexBarConfig()
        try SettingsSaveRequestApplier.apply(
            SettingsSaveRequests(
                openAIAccount: OpenAIAccountSettingsUpdate(
                    accountOrder: [],
                    accountUsageMode: .switchAccount,
                    accountOrderingMode: .quotaSort,
                    manualActivationBehavior: .updateConfigOnly,
                    remoteConnectionAccountID: nil,
                    hybridTargetSelection: nil,
                    webSocketSupportOverride: .disabled
                )
            ),
            to: &config
        )
        XCTAssertEqual(config.openAI.webSocketSupportOverride, .disabled)
    }

    func testHTTPAndSOCKSProbesFollowTunnelResult() throws {
        let httpSuccess = try LocalProxyStub.http(status: 200)
        defer { httpSuccess.close() }
        let httpProxy = try XCTUnwrap(
            OpenAIAccountGatewayConfiguredProxy(kind: .http, host: "127.0.0.1", port: httpSuccess.port, username: "user", password: "secret")
        )
        XCTAssertTrue(
            CodexWebSocketProxyProbe.supportsWebSocketTunnel(
                through: httpProxy,
                destinationHost: "chatgpt.com",
                destinationPort: 443,
                timeout: 2
            )
        )
        XCTAssertTrue(httpSuccess.request.contains("CONNECT chatgpt.com:443"))
        XCTAssertTrue(httpSuccess.request.contains("Proxy-Authorization: Basic "))

        let httpFailure = try LocalProxyStub.http(status: 403)
        defer { httpFailure.close() }
        let failingProxy = try XCTUnwrap(
            OpenAIAccountGatewayConfiguredProxy(kind: .http, host: "127.0.0.1", port: httpFailure.port)
        )
        XCTAssertFalse(
            CodexWebSocketProxyProbe.supportsWebSocketTunnel(
                through: failingProxy,
                destinationHost: "chatgpt.com",
                destinationPort: 443,
                timeout: 2
            )
        )

        let socks = try LocalProxyStub.socks(success: true)
        defer { socks.close() }
        let socksProxy = try XCTUnwrap(
            OpenAIAccountGatewayConfiguredProxy(kind: .socks, host: "127.0.0.1", port: socks.port, username: "user", password: "secret")
        )
        XCTAssertTrue(
            CodexWebSocketProxyProbe.supportsWebSocketTunnel(
                through: socksProxy,
                destinationHost: "chatgpt.com",
                destinationPort: 443,
                timeout: 2
            )
        )

        let refused = try XCTUnwrap(OpenAIAccountGatewayConfiguredProxy(kind: .http, host: "127.0.0.1", port: 1))
        XCTAssertFalse(
            CodexWebSocketProxyProbe.supportsWebSocketTunnel(
                through: refused,
                destinationHost: "chatgpt.com",
                destinationPort: 443,
                timeout: 0.4
            )
        )
    }

    func testRemoteProviderProbesItsOwnHost() throws {
        let config = self.compatibleConfig(baseURL: "https://api.example.com/v1")
        let route = try CodexRouteResolver.resolve(config: config)
        var destination: CodexWebSocketDestination?
        let coordinator = self.coordinator(
            environment: { ["https_proxy": "http://127.0.0.1:7890"] },
            probe: { _, probed in
                destination = probed
                return false
            }
        )
        XCTAssertEqual(coordinator.directive(for: config, route: route), .write(false))
        XCTAssertEqual(destination?.host, "api.example.com")
        XCTAssertEqual(destination?.port, 443)
    }

    private func coordinator(
        environment: @escaping () -> [String: String],
        systemProxy: @escaping () -> OpenAIAccountGatewaySystemProxySnapshot? = { nil },
        probe: @escaping (OpenAIAccountGatewayConfiguredProxy, CodexWebSocketDestination) -> Bool
    ) -> CodexWebSocketSupportCoordinator {
        CodexWebSocketSupportCoordinator(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            environment: environment,
            systemProxy: systemProxy,
            cache: CodexWebSocketProbeCache(ttl: 600),
            probe: probe
        )
    }

    private func oauthConfig() -> CodexBarConfig {
        let account = CodexBarProviderAccount(
            id: "acct_ws",
            kind: .oauthTokens,
            label: "ws@example.com",
            email: "ws@example.com",
            openAIAccountId: "acct_ws",
            accessToken: "access-ws",
            refreshToken: "refresh-ws",
            idToken: "id-ws"
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        return CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )
    }

    private func compatibleConfig(baseURL: String) -> CodexBarConfig {
        let account = CodexBarProviderAccount(id: "acct_direct", kind: .apiKey, label: "direct", apiKey: "fixture-key")
        let provider = CodexBarProvider(
            id: "direct",
            kind: .openAICompatible,
            label: "Direct",
            baseURL: baseURL,
            activeAccountId: account.id,
            accounts: [account]
        )
        return CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )
    }
}

@MainActor
final class CodexWebSocketSupportSettingsTests: XCTestCase {
    func testSettingsOverrideRoundTripsThroughCoordinator() throws {
        let account = TokenAccount(
            email: "ws@example.com",
            accountId: "acct_ws",
            accessToken: "access-ws",
            refreshToken: "refresh-ws",
            idToken: "id-ws"
        )
        let stored = CodexBarProviderAccount(
            id: account.accountId,
            kind: .oauthTokens,
            label: account.email,
            email: account.email,
            openAIAccountId: account.accountId,
            accessToken: account.accessToken,
            refreshToken: account.refreshToken,
            idToken: account.idToken
        )
        let provider = CodexBarProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: stored.id,
            accounts: [stored]
        )
        let config = CodexBarConfig(
            active: CodexBarActiveSelection(providerId: provider.id, accountId: stored.id),
            providers: [provider]
        )
        let coordinator = SettingsWindowCoordinator(config: config, accounts: [account], historicalModels: [])
        coordinator.update(\.webSocketSupportOverride, to: .disabled, field: .webSocketSupportOverride)
        let sink = WebSocketSettingsSink(config: config)
        _ = try coordinator.save(using: sink)
        XCTAssertEqual(sink.config.openAI.webSocketSupportOverride, .disabled)

        let reopened = SettingsWindowCoordinator(config: sink.config, accounts: [account], historicalModels: [])
        XCTAssertEqual(reopened.draft.webSocketSupportOverride, .disabled)
    }
}

@MainActor
private final class WebSocketSettingsSink: SettingsSaveRequestApplying {
    var config: CodexBarConfig

    init(config: CodexBarConfig) {
        self.config = config
    }

    func applySettingsSaveRequests(_ requests: SettingsSaveRequests) throws {
        try SettingsSaveRequestApplier.apply(requests, to: &self.config)
    }
}

private final class LocalProxyStub {
    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var capturedRequest = ""
    private var started = false
    private let serve: (Int32, (String) -> Void) -> Void

    var request: String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.capturedRequest
    }

    static func http(status: Int) throws -> LocalProxyStub {
        let stub = try LocalProxyStub { client, record in
            let request = self.readUntilBlankLine(client)
            record(request)
            let response = "HTTP/1.1 \(status) Connection Established\r\n\r\n"
            _ = self.writeAll(client, data: Data(response.utf8))
        }
        stub.start()
        return stub
    }

    static func socks(success: Bool) throws -> LocalProxyStub {
        let stub = try LocalProxyStub { client, _ in
            _ = self.readUntilCount(client, minimum: 2)
            _ = self.writeAll(client, data: Data([0x05, 0x02]))
            _ = self.readUntilCount(client, minimum: 2)
            _ = self.writeAll(client, data: Data([0x01, 0x00]))
            _ = self.readUntilCount(client, minimum: 4)
            let reply: [UInt8] = success
                ? [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
                : [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
            _ = self.writeAll(client, data: Data(reply))
        }
        stub.start()
        return stub
    }

    private init(serve: @escaping (Int32, (String) -> Void) -> Void) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubError.socket }
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw StubError.bind
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw StubError.bind
        }
        self.listenFD = fd
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        self.serve = serve
    }

    func close() {
        Darwin.close(self.listenFD)
    }

    private func start() {
        guard self.started == false else { return }
        self.started = true
        let listenFD = self.listenFD
        let serve = self.serve
        DispatchQueue.global().async {
            let client = Darwin.accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            let size = socklen_t(MemoryLayout<timeval>.size)
            _ = Darwin.setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
            serve(client) { captured in
                self.lock.lock()
                self.capturedRequest = captured
                self.lock.unlock()
            }
        }
    }

    private static func readUntilBlankLine(_ fd: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil && data.count < 4096 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func readUntilCount(_ fd: Int32, minimum: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count < minimum {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        return data
    }

    private static func writeAll(_ fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var sent = 0
            while sent < data.count {
                let count = Darwin.write(fd, base.advanced(by: sent), data.count - sent)
                if count > 0 {
                    sent += count
                } else {
                    return false
                }
            }
            return true
        }
    }

    private enum StubError: Error {
        case socket
        case bind
    }
}
