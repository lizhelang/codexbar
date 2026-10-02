import Combine
import Foundation
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    init() { self.refresh() }

    /// Read the operating system's state. Opening settings never registers a login item.
    func refresh() {
        let status = SMAppService.mainApp.status
        self.isEnabled = status == .enabled || status == .requiresApproval
        self.requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        self.errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            self.errorMessage = error.localizedDescription
        }
        self.refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
