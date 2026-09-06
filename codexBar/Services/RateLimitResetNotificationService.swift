import Foundation
import UserNotifications

@MainActor
final class RateLimitResetNotificationService {
    static let shared = RateLimitResetNotificationService()

    static let notifiedKeysDefaultsKey = "rateLimitResetNotifiedCreditKeys"

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var isEvaluating = false

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
    }

    func evaluate(accounts: [TokenAccount], now: Date = Date()) {
        guard self.isEvaluating == false else { return }
        let pending = RateLimitResetCreditPresentation.pendingNotificationKeys(
            from: accounts,
            now: now,
            alreadyNotified: self.notifiedKeys
        )
        guard pending.isEmpty == false else { return }

        self.isEvaluating = true
        Task {
            defer { self.isEvaluating = false }
            await self.deliver(pending)
        }
    }

    private var notifiedKeys: Set<String> {
        Set(self.defaults.stringArray(forKey: Self.notifiedKeysDefaultsKey) ?? [])
    }

    private func remember(keys: [String]) {
        var stored = self.notifiedKeys
        stored.formUnion(keys)
        self.defaults.set(Array(stored), forKey: Self.notifiedKeysDefaultsKey)
    }

    private func deliver(_ items: [RateLimitResetCreditItem]) async {
        let granted = await self.requestAuthorizationIfNeeded()
        guard granted else { return }

        var deliveredKeys: [String] = []
        for item in items {
            let key = RateLimitResetCreditPolicy.notificationKey(
                creditId: item.creditId,
                expiresAt: item.expiresAt
            )
            let content = UNMutableNotificationContent()
            content.title = L.resetCreditNotificationTitle
            content.body = L.resetCreditNotificationBody(
                item.accountLabel,
                RateLimitResetCreditPresentation.relativeExpiry(item.expiresAt)
            )
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "codexbar.reset-credit.\(key)",
                content: content,
                trigger: nil
            )
            do {
                try await self.center.add(request)
                deliveredKeys.append(key)
            } catch {
                continue
            }
        }

        if deliveredKeys.isEmpty == false {
            self.remember(keys: deliveredKeys)
        }
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await self.center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await self.center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }
}
