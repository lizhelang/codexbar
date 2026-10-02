import Combine
import Foundation

/// Application-wide tasks continue when the menu is closed.
@MainActor
final class ApplicationPreferencesRuntime: LifecycleControlling {
    static let shared = ApplicationPreferencesRuntime()
    private var collectionTask: Task<Void, Never>?
    private var preferencesCancellable: AnyCancellable?
    private var syncCancellables: Set<AnyCancellable> = []
    private var pendingUsagePublication: DispatchWorkItem?

    func start() {
        guard self.collectionTask == nil else { return }
        _ = DeviceUsageSyncService.shared
        self.scheduleCollection(interval: ApplicationPreferencesStore.shared.preferences.refreshIntervalSeconds)
        self.preferencesCancellable = ApplicationPreferencesStore.shared.$preferences
            .map(\.refreshIntervalSeconds).removeDuplicates().dropFirst()
            .sink { [weak self] interval in self?.scheduleCollection(interval: interval) }
        TokenStore.shared.$localCostSummary.dropFirst().sink { [weak self] _ in self?.scheduleUsagePublication() }
            .store(in: &self.syncCancellables)
        ToolUsageStore.shared.$snapshots.dropFirst().sink { [weak self] _ in self?.scheduleUsagePublication() }
            .store(in: &self.syncCancellables)
        ApplicationPreferencesStore.shared.$preferences.map(\.disabledTools).removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleUsagePublication() }
            .store(in: &self.syncCancellables)
        self.publishLocalUsage()
        ScheduledUsageExportService.shared.start()
    }

    private func scheduleCollection(interval: TimeInterval) {
        self.collectionTask?.cancel()
        self.collectionTask = Task {
            while !Task.isCancelled {
                ToolUsageStore.shared.refreshIfNeeded()
                if ApplicationPreferencesStore.shared.preferences.enabledTools.contains("codex") {
                    TokenStore.shared.refreshLocalCostSummary(minimumInterval: interval, refreshSessionCache: true)
                }
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
    }

    func stop() {
        self.collectionTask?.cancel()
        self.collectionTask = nil
        self.preferencesCancellable = nil
        self.syncCancellables.removeAll()
        self.pendingUsagePublication?.cancel()
        self.pendingUsagePublication = nil
        ScheduledUsageExportService.shared.stop()
    }

    private func scheduleUsagePublication() {
        // Read after @Published assigns, coalescing all sources changed in this main-loop turn.
        guard self.pendingUsagePublication == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.collectionTask != nil else { return }
            self.pendingUsagePublication = nil
            self.publishLocalUsage()
        }
        self.pendingUsagePublication = work
        DispatchQueue.main.async(execute: work)
    }

    private func publishLocalUsage() {
        let enabled = ApplicationPreferencesStore.shared.preferences.enabledTools
        DeviceUsageSyncService.shared.publishLocalUsage(
            codex: enabled.contains("codex") ? TokenStore.shared.localCostSummary : .empty,
            tools: ToolUsageStore.shared.snapshots.filter { enabled.contains($0.key.rawValue) },
            enabledToolIDs: Set(enabled)
        )
    }
}

/// An export deliberately contains aggregate usage only, never session titles, paths or accounts.
nonisolated struct ScheduledUsageExport: Codable, Sendable {
    struct Source: Codable, Sendable {
        var tool: String
        var dailyEntries: [ToolUsageDailyEntry]
    }
    var schemaVersion = 1
    var exportedAt: Date
    var sources: [Source]
}

@MainActor
final class ScheduledUsageExportService: ObservableObject, LifecycleControlling {
    static let shared = ScheduledUsageExportService()
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var lastExportAt: Date?
    @Published private(set) var errorMessage: String?
    private let preferencesStore: ApplicationPreferencesStore
    private let makeSnapshot: () -> ScheduledUsageExport
    private var preferencesCancellable: AnyCancellable?
    private var exportTask: Task<Void, Never>?
    private var hasStarted = false

    init(preferencesStore: ApplicationPreferencesStore? = nil, makeSnapshot: (() -> ScheduledUsageExport)? = nil) {
        self.preferencesStore = preferencesStore ?? .shared
        self.makeSnapshot = makeSnapshot ?? {
            let enabled = ApplicationPreferencesStore.shared.preferences.enabledTools
            var sources: [ScheduledUsageExport.Source] = []
            if enabled.contains("codex") {
                sources.append(.init(tool: "codex", dailyEntries: TokenStore.shared.localCostSummary.dailyEntries.map {
                    ToolUsageDailyEntry(date: $0.date, totalTokens: $0.totalTokens, costUSD: $0.costIsComplete ? $0.costUSD : nil)
                }))
            }
            sources += ToolUsageClient.allCases.filter { enabled.contains($0.rawValue) }.map {
                .init(tool: $0.rawValue, dailyEntries: ToolUsageStore.shared.snapshot(for: $0).dailyEntries)
            }
            return ScheduledUsageExport(exportedAt: Date(), sources: sources)
        }
    }

    func start() {
        guard !self.hasStarted else { return }
        self.hasStarted = true
        self.preferencesCancellable = self.preferencesStore.$preferences
            .map { ExportConfiguration(enabled: $0.scheduledExportEnabled, directory: $0.scheduledExportDirectory,
                                       interval: $0.scheduledExportIntervalSeconds) }
            .removeDuplicates()
            .sink { [weak self] configuration in self?.schedule(configuration) }
    }

    func stop() {
        self.hasStarted = false
        self.exportTask?.cancel()
        self.exportTask = nil
        self.preferencesCancellable = nil
    }

    @discardableResult
    func exportNow() -> URL? {
        let directory = self.preferencesStore.preferences.scheduledExportDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            self.errorMessage = L.zh ? "请先选择用量导出目录。" : "Choose an export folder first."
            return nil
        }
        do {
            let snapshot = self.makeSnapshot()
            let directoryURL = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = directoryURL.appendingPathComponent("codexbar-usage-\(formatter.string(from: snapshot.exportedAt))-\(UUID().uuidString.prefix(6)).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            self.lastExportURL = url
            self.lastExportAt = snapshot.exportedAt
            self.errorMessage = nil
            return url
        } catch {
            self.errorMessage = error.localizedDescription
            return nil
        }
    }

    private struct ExportConfiguration: Equatable {
        var enabled: Bool
        var directory: String
        var interval: TimeInterval
    }

    private func schedule(_ configuration: ExportConfiguration) {
        self.exportTask?.cancel()
        self.exportTask = nil
        guard configuration.enabled, !configuration.directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.exportTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(configuration.interval)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self.exportNow()
            }
        }
    }
}
