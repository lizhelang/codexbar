import Combine
import Foundation

struct SubscriptionRecord: Identifiable, Codable, Equatable {
    enum Kind: String, CaseIterable, Codable {
        case subscription, topUp
    }

    enum Interval: String, CaseIterable, Codable {
        case month, year
    }

    var id = UUID()
    var provider = "Codex"
    var planName = ""
    var kind: Kind = .subscription
    var amount: Double = 0
    var currency = "USD"
    var intervalCount = 1
    var interval: Interval = .month
    var startDate = Date()
    var autoRenew = true
    var nextRenewal: Date?
    var note = ""

    func estimatedNextRenewal(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard self.kind == .subscription, self.autoRenew else { return nil }
        if let nextRenewal { return nextRenewal }
        let component: Calendar.Component = self.interval == .month ? .month : .year
        // Count from the original billing date so a February clamp does not permanently
        // shift a subscription that started on the 29th, 30th or 31st.
        for occurrence in 1...1200 {
            let distance = occurrence * min(120, max(1, self.intervalCount))
            guard let next = calendar.date(byAdding: component, value: distance, to: self.startDate) else { return nil }
            if next > now { return next }
        }
        return nil
    }
}

enum SubscriptionRecordError: LocalizedError {
    case invalidProvider, invalidAmount, invalidCurrency, invalidInterval

    var errorDescription: String? {
        switch self {
        case .invalidProvider: return L.zh ? "请填写工具或服务名称。" : "Enter a tool or service name."
        case .invalidAmount: return L.zh ? "金额必须是大于或等于零的有效数字。" : "Enter a valid, nonnegative amount."
        case .invalidCurrency: return L.zh ? "请填写三位币种代码。" : "Enter a three-letter currency code."
        case .invalidInterval: return L.zh ? "周期必须在 1 至 120 之间。" : "The interval must be between 1 and 120."
        }
    }
}

@MainActor
final class SubscriptionRecordStore: ObservableObject {
    static let shared = SubscriptionRecordStore()
    static let storageKey = "codexbar.subscriptionRecords.v1"

    @Published private(set) var records: [SubscriptionRecord] = []
    @Published private(set) var loadError: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            self.records = try JSONDecoder().decode([SubscriptionRecord].self, from: data)
        } catch {
            self.loadError = L.zh ? "无法读取订阅记录，原始数据已保留。" : "Subscription records could not be read. Original data was preserved."
        }
    }

    func save(_ record: SubscriptionRecord) throws {
        var normalized = record
        normalized.provider = record.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.planName = record.planName.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.currency = record.currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.provider.isEmpty == false else { throw SubscriptionRecordError.invalidProvider }
        guard normalized.amount.isFinite, normalized.amount >= 0 else { throw SubscriptionRecordError.invalidAmount }
        guard normalized.currency.count == 3, normalized.currency.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) && $0.isASCII }) else {
            throw SubscriptionRecordError.invalidCurrency
        }
        guard (1...120).contains(normalized.intervalCount) else { throw SubscriptionRecordError.invalidInterval }
        var updated = self.records
        if let index = updated.firstIndex(where: { $0.id == normalized.id }) {
            updated[index] = normalized
        } else {
            updated.append(normalized)
        }
        try self.persist(updated)
    }

    func remove(id: UUID) throws {
        try self.persist(self.records.filter { $0.id != id })
    }

    private func persist(_ records: [SubscriptionRecord]) throws {
        let data = try JSONEncoder().encode(records)
        // Keep unreadable prior content recoverable rather than silently replacing it.
        if self.loadError != nil, let previous = self.defaults.data(forKey: Self.storageKey) {
            self.defaults.set(previous, forKey: Self.storageKey + ".unreadableBackup")
        }
        self.defaults.set(data, forKey: Self.storageKey)
        self.records = records
        self.loadError = nil
    }
}
