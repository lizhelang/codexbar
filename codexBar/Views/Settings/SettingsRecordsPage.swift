import Combine
import Foundation
import SwiftUI

@MainActor
final class SettingsRecordsViewModel: ObservableObject {
    @Published private(set) var snapshot: RecordsSnapshot?
    @Published private(set) var isLoadingSnapshot = false
    @Published private(set) var isRefreshingAll = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = ""
    @Published var isModelsSummaryExpanded = false
    @Published var isWarningsExpanded = false

    private let service: any RecordsSnapshotServing
    private var requestToken: UInt64 = 0

    init(service: any RecordsSnapshotServing) {
        self.service = service
    }

    var filteredSessions: [HistoricalSessionRecord] {
        guard let snapshot = self.snapshot else { return [] }
        let query = self.normalizedQuery
        guard query.isEmpty == false else { return snapshot.sessions }
        return snapshot.sessions.filter {
            $0.sessionID.localizedCaseInsensitiveContains(query) ||
            $0.modelID.localizedCaseInsensitiveContains(query)
        }
    }

    var filteredModels: [HistoricalModelRecord] {
        guard let snapshot = self.snapshot else { return [] }
        let query = self.normalizedQuery
        guard query.isEmpty == false else { return snapshot.models }

        let visibleModelIDs = Set(self.filteredSessions.map(\.modelID))
        return snapshot.models.filter {
            visibleModelIDs.contains($0.modelID) ||
            $0.modelID.localizedCaseInsensitiveContains(query)
        }
    }

    var archivedSessionCount: Int {
        self.filteredSessions.filter(\.isArchived).count
    }

    var activeSessionCount: Int {
        self.filteredSessions.count - self.archivedSessionCount
    }

    var hasSnapshot: Bool {
        self.snapshot != nil
    }

    var shouldShowSkeleton: Bool {
        self.snapshot == nil && self.isLoadingSnapshot
    }

    var statusText: String {
        if self.isRefreshingAll {
            return L.settingsRecordsRefreshingAll
        }
        if self.isLoadingSnapshot {
            return self.snapshot == nil
                ? L.settingsRecordsLoading
                : L.settingsRecordsRefreshingIncremental
        }
        guard let snapshot = self.snapshot else {
            return L.settingsRecordsIdle
        }
        return L.settingsRecordsLastUpdated(
            snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    func pageDidAppear() {
        guard self.isLoadingSnapshot == false, self.isRefreshingAll == false else { return }
        self.loadCurrent()
    }

    func retryLoad() {
        self.loadCurrent()
    }

    func loadCurrent() {
        let requestToken = self.beginRequest(isRefreshAll: false)
        Task {
            do {
                let snapshot = try await self.service.loadCurrent()
                self.finishRequest(
                    token: requestToken,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshAll: false
                )
            } catch {
                self.finishRequest(
                    token: requestToken,
                    snapshot: nil,
                    errorMessage: self.displayMessage(for: error),
                    isRefreshAll: false
                )
            }
        }
    }

    func refreshAll(timeout: TimeInterval = 15) {
        guard self.isRefreshingAll == false else { return }
        let requestToken = self.beginRequest(isRefreshAll: true)
        Task {
            do {
                let snapshot = try await self.service.refreshAll(timeout: timeout)
                self.finishRequest(
                    token: requestToken,
                    snapshot: snapshot,
                    errorMessage: nil,
                    isRefreshAll: true
                )
            } catch {
                self.finishRequest(
                    token: requestToken,
                    snapshot: nil,
                    errorMessage: self.displayMessage(for: error),
                    isRefreshAll: true
                )
            }
        }
    }

    private var normalizedQuery: String {
        self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginRequest(isRefreshAll: Bool) -> UInt64 {
        self.requestToken += 1
        self.errorMessage = nil
        if isRefreshAll {
            self.isRefreshingAll = true
            self.isLoadingSnapshot = false
        } else {
            self.isLoadingSnapshot = true
        }
        return self.requestToken
    }

    private func finishRequest(
        token: UInt64,
        snapshot: RecordsSnapshot?,
        errorMessage: String?,
        isRefreshAll: Bool
    ) {
        guard token == self.requestToken else { return }
        self.isLoadingSnapshot = false
        if isRefreshAll {
            self.isRefreshingAll = false
        }
        if let snapshot {
            self.snapshot = snapshot
        }
        self.errorMessage = errorMessage
    }

    private func displayMessage(for error: Error) -> String {
        if let serviceError = error as? RecordsSnapshotServiceError,
           case .timedOut = serviceError {
            return L.settingsRecordsRefreshTimeout
        }
        return error.localizedDescription
    }
}

typealias SettingsRecordsModel = SettingsRecordsViewModel

struct SettingsRecordsPage: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    let onOpenUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L.settingsRecordsPageTitle)
                .font(.system(size: 16, weight: .semibold))

            Text(L.settingsRecordsPageHint)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsRecordsToolbar(
                recordsModel: self.recordsModel,
                onOpenUsage: self.onOpenUsage
            )

            if let errorMessage = self.recordsModel.errorMessage {
                SettingsRecordsInlineMessage(
                    message: errorMessage,
                    showsRetry: self.recordsModel.hasSnapshot == false,
                    onRetry: self.recordsModel.retryLoad
                )
            }

            if self.recordsModel.shouldShowSkeleton {
                SettingsRecordsLoadingSection()
            } else if self.recordsModel.hasSnapshot {
                SettingsRecordsOverview(recordsModel: self.recordsModel)
                SettingsRecordsSessionsSection(recordsModel: self.recordsModel)
                SettingsRecordsModelsSection(recordsModel: self.recordsModel)

                if self.recordsModel.snapshot?.warnings.isEmpty == false {
                    SettingsRecordsWarningsSection(recordsModel: self.recordsModel)
                }
            } else {
                SettingsRecordsEmptyState(onRetry: self.recordsModel.retryLoad)
            }
        }
        .onAppear {
            self.recordsModel.pageDidAppear()
        }
    }
}

private struct SettingsRecordsToolbar: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel
    let onOpenUsage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                TextField(L.settingsRecordsSearchPlaceholder, text: self.$recordsModel.searchText)
                    .textFieldStyle(.roundedBorder)

                Button(L.settingsRecordsRefreshAction) {
                    self.recordsModel.refreshAll()
                }
                .disabled(self.recordsModel.isRefreshingAll)

                Button(L.settingsRecordsGoToUsageAction) {
                    self.onOpenUsage()
                }
            }

            Text(self.recordsModel.statusText)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

private struct SettingsRecordsOverview: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    private var filteredSessionCount: Int {
        self.recordsModel.filteredSessions.count
    }

    private var totalSessionCount: Int {
        self.recordsModel.snapshot?.sessions.count ?? 0
    }

    private var modelCount: Int {
        self.recordsModel.filteredModels.count
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsRecordsMetricCard(
                title: L.settingsRecordsSessionsMetric,
                value: "\(self.filteredSessionCount)",
                footnote: self.totalSessionCount == self.filteredSessionCount
                    ? L.settingsRecordsAllResults
                    : L.settingsRecordsFilteredResults(self.filteredSessionCount, total: self.totalSessionCount)
            )
            SettingsRecordsMetricCard(
                title: L.settingsRecordsModelsMetric,
                value: "\(self.modelCount)",
                footnote: L.settingsRecordsActiveModelsFootnote
            )
            SettingsRecordsMetricCard(
                title: L.settingsRecordsArchivedMetric,
                value: "\(self.recordsModel.archivedSessionCount)",
                footnote: L.settingsRecordsActiveArchivedFootnote(self.recordsModel.activeSessionCount)
            )
        }
    }
}

private struct SettingsRecordsMetricCard: View {
    let title: String
    let value: String
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(self.value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
            Text(self.footnote)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct SettingsRecordsSessionsSection: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.settingsRecordsSessionsTitle)
                .font(.system(size: 12, weight: .medium))

            Text(L.settingsRecordsSessionsHint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if self.recordsModel.filteredSessions.isEmpty {
                Text(self.recordsModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? L.settingsRecordsSessionsEmpty
                     : L.settingsRecordsNoSearchResults)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(self.recordsModel.filteredSessions) { session in
                        SettingsRecordsSessionRow(session: session)
                    }
                }
            }
        }
    }
}

private struct SettingsRecordsSessionRow: View {
    let session: HistoricalSessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.session.sessionID)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    Text(self.session.modelID)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                Text(self.session.isArchived ? L.settingsRecordsArchivedBadge : L.settingsRecordsCurrentBadge)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(self.session.isArchived ? .orange : .accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill((self.session.isArchived ? Color.orange : Color.accentColor).opacity(0.12))
                    )
            }

            HStack(alignment: .top, spacing: 18) {
                SettingsRecordsInfoColumn(
                    title: L.settingsRecordsStartedAtTitle,
                    value: self.session.startedAt.formatted(date: .abbreviated, time: .shortened)
                )
                SettingsRecordsInfoColumn(
                    title: L.settingsRecordsLastActivityTitle,
                    value: self.session.lastActivityAt.formatted(date: .abbreviated, time: .shortened)
                )
                SettingsRecordsInfoColumn(
                    title: L.settingsRecordsTotalTokensTitle,
                    value: "\(self.session.totalTokens)"
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct SettingsRecordsInfoColumn: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(self.value)
                .font(.system(size: 11))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRecordsModelsSection: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        DisclosureGroup(isExpanded: self.$recordsModel.isModelsSummaryExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if self.recordsModel.filteredModels.isEmpty {
                    Text(L.settingsRecordsModelsEmpty)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(self.recordsModel.filteredModels) { model in
                        SettingsRecordsModelRow(model: model)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.settingsRecordsModelsTitle)
                    .font(.system(size: 12, weight: .medium))
                Text(L.settingsRecordsModelsHint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsRecordsModelRow: View {
    let model: HistoricalModelRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(self.model.modelID)
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                Text(L.settingsRecordsModelSummary(self.model.sessionCount))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            Text(self.model.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct SettingsRecordsWarningsSection: View {
    @ObservedObject var recordsModel: SettingsRecordsViewModel

    var body: some View {
        if let warnings = self.recordsModel.snapshot?.warnings {
            DisclosureGroup(isExpanded: self.$recordsModel.isWarningsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings) { warning in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(warning.message)
                                .font(.system(size: 11, weight: .medium))
                            Text(warning.sessionFilePath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.08))
                        )
                    }
                }
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.settingsRecordsWarningsTitle(warnings.count))
                        .font(.system(size: 12, weight: .medium))
                    Text(L.settingsRecordsWarningsHint)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SettingsRecordsLoadingSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 240, height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.10))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.10))
                        .frame(height: 10)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.06))
                )
                .redacted(reason: .placeholder)
            }
        }
    }
}

private struct SettingsRecordsInlineMessage: View {
    let message: String
    let showsRetry: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text(self.message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)

                if self.showsRetry {
                    Button(L.settingsRecordsRetryAction) {
                        self.onRetry()
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
        )
    }
}

private struct SettingsRecordsEmptyState: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.settingsRecordsEmptyState)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Button(L.settingsRecordsRetryAction) {
                self.onRetry()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
