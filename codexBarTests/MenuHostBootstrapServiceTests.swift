import Foundation
import XCTest

final class MenuHostBootstrapServiceTests: XCTestCase {
    func testHelperNeedsRefreshWhenSignatureMissingEvenIfVersionMatches() throws {
        let sourceBundle = try self.makeBundle(
            name: "Source",
            version: "9",
            shortVersion: "1.1.9",
            executableSize: 128,
            executableMTime: 1_776_388_953
        )
        let helperBundle = try self.makeBundle(
            name: "Helper",
            version: "9",
            shortVersion: "1.1.9",
            executableSize: 96,
            executableMTime: 1_776_388_178,
            extraInfo: [
                MenuHostBootstrapService.helperSourceVersionKey: "9",
            ]
        )

        XCTAssertTrue(
            MenuHostBootstrapService.helperNeedsRefresh(
                helperBundle: helperBundle,
                sourceBundle: sourceBundle
            )
        )
    }

    func testHelperDoesNotRefreshWhenStoredSignatureMatchesSource() throws {
        let sourceBundle = try self.makeBundle(
            name: "Source",
            version: "9",
            shortVersion: "1.1.9",
            executableSize: 128,
            executableMTime: 1_776_388_953
        )
        let sourceSignature = try XCTUnwrap(
            MenuHostBootstrapService.helperSourceSignature(for: sourceBundle)
        )
        let helperBundle = try self.makeBundle(
            name: "Helper",
            version: "9",
            shortVersion: "1.1.9",
            executableSize: 128,
            executableMTime: 1_776_388_953,
            extraInfo: [
                MenuHostBootstrapService.helperSourceVersionKey: "9",
                MenuHostBootstrapService.helperSourceSignatureKey: sourceSignature,
            ]
        )

        XCTAssertFalse(
            MenuHostBootstrapService.helperNeedsRefresh(
                helperBundle: helperBundle,
                sourceBundle: sourceBundle
            )
        )
    }

    func testHelperRefreshesWhenStoredSignatureDiffersAtSameVersion() throws {
        let sourceBundle = try self.makeBundle(
            name: "Source",
            version: "9",
            shortVersion: "1.1.9",
            executableSize: 128,
            executableMTime: 1_776_388_953
        )
        let helperBundle = try self.makeBundle(
            name: "Helper",
            version: "9",
            shortVersion: "1.1.9",
            executableSize: 96,
            executableMTime: 1_776_388_178,
            extraInfo: [
                MenuHostBootstrapService.helperSourceVersionKey: "9",
                MenuHostBootstrapService.helperSourceSignatureKey: "9|1.1.9|96|1776388178",
            ]
        )

        XCTAssertTrue(
            MenuHostBootstrapService.helperNeedsRefresh(
                helperBundle: helperBundle,
                sourceBundle: sourceBundle
            )
        )
    }

    private func makeBundle(
        name: String,
        version: String,
        shortVersion: String,
        executableSize: Int,
        executableMTime: Int,
        extraInfo: [String: Any] = [:]
    ) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("\(name).app", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let executableURL = macOS.appendingPathComponent(name)
        try Data(repeating: 0x41, count: executableSize).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(executableMTime))],
            ofItemAtPath: executableURL.path
        )

        var info: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "test.\(name.lowercased())",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": version,
        ]
        extraInfo.forEach { info[$0.key] = $0.value }

        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))

        return try XCTUnwrap(Bundle(url: root))
    }
}
