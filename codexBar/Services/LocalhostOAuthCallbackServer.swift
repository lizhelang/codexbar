import Foundation

enum LocalhostOAuthCallbackServerError: LocalizedError {
    case socketCreationFailed
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Failed to create localhost OAuth callback socket."
        case .bindFailed(let code):
            return "Failed to bind localhost OAuth callback listener (errno \(code))."
        case .listenFailed(let code):
            return "Failed to listen for localhost OAuth callback (errno \(code))."
        }
    }
}

final class LocalhostOAuthCallbackServer {
    let port: UInt16
    let callbackPath: String

    private let queue = DispatchQueue(label: "lzl.codexbar.oauth-callback-server")
    private let onCallback: @MainActor (String) -> Void
    private let acceptsCallback: @Sendable (String) -> Bool

    private let stateLock = NSLock()
    private var listener: (id: UUID, fd: Int32)?

    init(
        port: UInt16 = 1455,
        callbackPath: String = "/auth/callback",
        acceptsCallback: @escaping @Sendable (String) -> Bool = { _ in true },
        onCallback: @escaping @MainActor (String) -> Void
    ) {
        self.port = port
        self.callbackPath = callbackPath
        self.acceptsCallback = acceptsCallback
        self.onCallback = onCallback
    }

    func start() throws {
        self.stop()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalhostOAuthCallbackServerError.socketCreationFailed
        }

        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = self.port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        memset(&address.sin_zero, 0, MemoryLayout.size(ofValue: address.sin_zero))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw LocalhostOAuthCallbackServerError.bindFailed(errno: code)
        }

        guard Darwin.listen(fd, 5) == 0 else {
            let code = errno
            close(fd)
            throw LocalhostOAuthCallbackServerError.listenFailed(errno: code)
        }

        let listenerID = UUID()
        self.stateLock.lock()
        self.listener = (listenerID, fd)
        self.stateLock.unlock()

        self.queue.async { [weak self] in
            self?.acceptLoop(serverFd: fd, listenerID: listenerID)
        }
    }

    func stop() {
        self.stop(listenerID: nil)
    }

    @discardableResult
    private func stop(listenerID: UUID?) -> Bool {
        self.stateLock.lock()
        guard let active = self.listener, listenerID == nil || active.id == listenerID else {
            self.stateLock.unlock()
            return false
        }
        self.listener = nil
        self.stateLock.unlock()
        shutdown(active.fd, SHUT_RDWR)
        close(active.fd)
        return true
    }

    private func isCurrent(_ id: UUID) -> Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.listener?.id == id
    }

    private func acceptLoop(serverFd: Int32, listenerID: UUID) {
        defer { self.stop(listenerID: listenerID) }
        while self.isCurrent(listenerID) {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else {
                if !self.isCurrent(listenerID) { break }
                continue
            }
            self.handle(clientFd: clientFd, listenerID: listenerID)
        }
    }

    private func handle(clientFd: Int32, listenerID: UUID) {
        defer { close(clientFd) }
        guard self.isCurrent(listenerID) else { return }
        // A partial local request must not prevent the browser callback from being handled.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(clientFd, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0,
              let request = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) else {
            self.write(response: Self.httpResponse(status: "400 Bad Request", body: "Invalid callback request."), to: clientFd)
            return
        }

        guard let callbackURL = Self.callbackURL(
            from: request,
            host: "localhost",
            port: self.port,
            callbackPath: self.callbackPath
        ) else {
            self.write(response: Self.httpResponse(status: "404 Not Found", body: "Callback route not found."), to: clientFd)
            return
        }
        guard self.acceptsCallback(callbackURL) else {
            self.write(response: Self.httpResponse(status: "400 Bad Request", body: "Callback does not match the pending login."), to: clientFd)
            return
        }

        guard self.isCurrent(listenerID) else { return }
        self.write(response: Self.successResponse, to: clientFd)
        guard self.stop(listenerID: listenerID) else { return }

        Task { @MainActor [callbackURL, onCallback] in
            onCallback(callbackURL)
        }
    }

    private func write(response: Data, to clientFd: Int32) {
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = send(clientFd, baseAddress, rawBuffer.count, 0)
        }
    }

    static func callbackURL(
        from request: String,
        host: String = "localhost",
        port: UInt16 = 1455,
        callbackPath: String = "/auth/callback"
    ) -> String? {
        guard let line = request.components(separatedBy: "\r\n").first,
              line.hasPrefix("GET ") else { return nil }

        let parts = line.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let pathAndQuery = parts[1]
        guard pathAndQuery.hasPrefix("/"),
              let components = URLComponents(string: "http://\(host):\(port)\(pathAndQuery)"),
              components.path == callbackPath, components.fragment == nil else { return nil }
        return components.string
    }

    private static func httpResponse(status: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        var data = Data(headers.utf8)
        data.append(bodyData)
        return data
    }

    private static let successResponse = LocalhostOAuthCallbackServer.httpResponse(
        status: "200 OK",
        body: """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Codexbar Login Received</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: #111;
              color: #f5f5f5;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            .card {
              width: min(92vw, 420px);
              padding: 28px 24px;
              border-radius: 18px;
              background: #1b1b1b;
              border: 1px solid #2c2c2c;
              box-shadow: 0 24px 60px rgba(0, 0, 0, 0.35);
            }
            h1 {
              margin: 0 0 10px;
              font-size: 22px;
            }
            p {
              margin: 0;
              color: #b7b7b7;
              line-height: 1.5;
            }
          </style>
        </head>
        <body>
          <div class="card">
            <h1>Login received</h1>
            <p>Codexbar captured the localhost callback. You can return to the app now.</p>
          </div>
        </body>
        </html>
        """
    )
}
