import Foundation
import XCTest

@MainActor
final class MenuHostBootstrapServiceTests: XCTestCase {
    func testCleanupRemovesLegacyBundleLeaseAndRoot() throws {
        let rootURL = try self.makeDirectory()
        let appURL = rootURL.appendingPathComponent("codexbar.app", isDirectory: true)
        let leaseURL = rootURL.appendingPathComponent("host.pid")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try Data("1234".utf8).write(to: leaseURL)

        let service = MenuHostBootstrapService(
            menuHostRootURL: rootURL,
            menuHostAppURL: appURL,
            menuHostLeaseURL: leaseURL,
            runningApplications: { _ in [] }
        )

        let result = service.cleanupLegacyArtifacts()

        XCTAssertTrue(result.removedAppBundle)
        XCTAssertTrue(result.removedLease)
        XCTAssertTrue(result.removedRootDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.path))
    }

    func testCleanupKeepsRootWhenNonLegacyArtifactsRemain() throws {
        let rootURL = try self.makeDirectory()
        let leaseURL = rootURL.appendingPathComponent("host.pid")
        let keepURL = rootURL.appendingPathComponent("keep.txt")
        try Data("1234".utf8).write(to: leaseURL)
        try Data("keep".utf8).write(to: keepURL)

        let service = MenuHostBootstrapService(
            menuHostRootURL: rootURL,
            menuHostAppURL: rootURL.appendingPathComponent("codexbar.app", isDirectory: true),
            menuHostLeaseURL: leaseURL,
            runningApplications: { _ in [] }
        )

        let result = service.cleanupLegacyArtifacts()

        XCTAssertTrue(result.removedLease)
        XCTAssertFalse(result.removedRootDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepURL.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
