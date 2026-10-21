import Darwin
import Foundation

/// OAuth client configuration is supplied locally, never bundled with source or release artifacts.
nonisolated struct AntigravityOAuthClientConfiguration: Codable, Equatable, Sendable {
    let clientID: String
    let clientSecret: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }

    static let clientIDEnvironmentKey = "CODEXBAR_ANTIGRAVITY_CLIENT_ID"
    static let clientSecretEnvironmentKey = "CODEXBAR_ANTIGRAVITY_CLIENT_SECRET"

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL = CodexPaths.codexBarRoot.appendingPathComponent("antigravity-oauth-client.json")
    ) throws -> Self {
        // A partial explicit override is an error; never combine two credential sources.
        if environment[self.clientIDEnvironmentKey] != nil || environment[self.clientSecretEnvironmentKey] != nil {
            guard let id = environment[self.clientIDEnvironmentKey],
                  let secret = environment[self.clientSecretEnvironmentKey] else {
                throw AntigravityAccountError.oauthClientConfigurationUnavailable
            }
            return try Self(clientID: id, clientSecret: secret).validated()
        }
        do {
            guard fileURL.isFileURL else { throw AntigravityAccountError.oauthClientConfigurationUnavailable }
            let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw AntigravityAccountError.oauthClientConfigurationUnavailable }
            defer { close(descriptor) }
            var metadata = stat()
            let maximumBytes = 16 * 1024
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_mode & 0o077 == 0, metadata.st_uid == geteuid(),
                  metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
                throw AntigravityAccountError.oauthClientConfigurationUnavailable
            }
            // Validate and read the same descriptor. A concurrent replacement cannot
            // redirect this read, and growth is bounded before allocating more memory.
            var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
            var used = 0
            while used < maximumBytes + 1 {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    read(descriptor, bytes.baseAddress!.advanced(by: used), maximumBytes + 1 - used)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw AntigravityAccountError.oauthClientConfigurationUnavailable }
                if count == 0 { break }
                used += count
            }
            guard used <= maximumBytes else { throw AntigravityAccountError.oauthClientConfigurationUnavailable }
            let data = Data(buffer.prefix(used))
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch {
            // Decoder and filesystem errors can contain sensitive input. Expose only a fixed message.
            throw AntigravityAccountError.oauthClientConfigurationUnavailable
        }
    }

    private func validated() throws -> Self {
        guard !self.clientID.isEmpty, self.clientID.utf8.count <= 512,
              self.clientID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              !self.clientSecret.isEmpty, self.clientSecret.utf8.count <= 4096,
              self.clientSecret.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
            throw AntigravityAccountError.oauthClientConfigurationUnavailable
        }
        return self
    }
}
