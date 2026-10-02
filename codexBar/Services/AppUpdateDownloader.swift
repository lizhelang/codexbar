import CryptoKit
import Foundation

@MainActor
protocol AppUpdateDownloading {
    func download(_ availability: AppUpdateAvailability) async throws -> URL
}

enum AppUpdateDownloadError: LocalizedError {
    case insecureURL
    case invalidResponse
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .insecureURL: L.zh ? "更新下载地址必须使用 HTTPS。" : "Update downloads require HTTPS."
        case .invalidResponse: L.zh ? "更新下载失败，请稍后重试。" : "Update download failed. Please try again."
        case .checksumMismatch: L.zh ? "更新文件校验失败，已丢弃下载。" : "Update checksum failed. The download was discarded."
        }
    }
}

/// Downloads our selected release asset; installing/restarting is always user initiated.
@MainActor
struct LiveAppUpdateDownloader: AppUpdateDownloading {
    var session: URLSession = .shared
    var cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("codexbar/Updates", isDirectory: true)

    func download(_ availability: AppUpdateAvailability) async throws -> URL {
        let artifact = availability.selectedArtifact
        guard artifact.downloadURL.scheme?.lowercased() == "https" else { throw AppUpdateDownloadError.insecureURL }
        var request = URLRequest(url: artifact.downloadURL)
        request.timeoutInterval = 300
        let (temporaryURL, response) = try await self.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else { throw AppUpdateDownloadError.invalidResponse }
        if let checksum = artifact.sha256, !checksum.isEmpty {
            let actual = try Self.sha256(of: temporaryURL)
            guard actual == checksum.lowercased().replacingOccurrences(of: "sha256:", with: "") else {
                throw AppUpdateDownloadError.checksumMismatch
            }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        let safeVersion = availability.release.version.filter { $0.isNumber || $0 == "." || $0 == "-" }
        let destination = self.cacheDirectory.appendingPathComponent(
            "codexbar-\(safeVersion)-\(artifact.architecture.rawValue).\(artifact.format.rawValue)"
        )
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
