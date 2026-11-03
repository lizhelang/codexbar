import SwiftUI

struct CodexQuotaResumeView: View {
    @ObservedObject var coordinator: CodexQuotaResumeCoordinator
    let accounts: [TokenAccount]
    @State private var selectedAccountID: String?

    init(coordinator: CodexQuotaResumeCoordinator = .shared, accounts: [TokenAccount]) {
        self.coordinator = coordinator
        self.accounts = accounts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L.zh ? "额度恢复后自动继续" : "Continue after quota resets", isOn: self.enabledBinding)
            .accessibilityIdentifier("codexbar.quota-resume.enabled")

            if !self.coordinator.state.enabled {
                Picker(L.zh ? "监测账号" : "Account to monitor", selection: Binding(
                    get: { self.selectedAccountID ?? "" },
                    set: {
                        self.selectedAccountID = $0.isEmpty ? nil : $0
                        self.coordinator.accountSelectionDidChange()
                    }
                )) {
                    Text(L.zh ? "桌面端当前账号（自动识别）" : "Current desktop account (automatic)").tag("")
                    ForEach(self.accounts.filter { !$0.isSuspended && !$0.tokenExpired }) { account in
                        Text(account.email).tag(account.id)
                    }
                }
                .accessibilityIdentifier("codexbar.quota-resume.account")
            }

            if let account = self.displayedAccount {
                Text((L.zh ? "监测账号：" : "Monitoring: ") + account.email)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("codexbar.quota-resume.resolved-account")
            }

            Text(L.zh
                ? "选择桌面端当前账号后，确认下方要守候的线程。额度恢复时会在原线程继续；手动停止或取消守候会终止等待。电脑需保持唤醒、联网且两个应用运行。"
                : "Select the current desktop account, then confirm the chats to watch below. Quota recovery continues the original chat. Stopping or cancelling ends the wait. Keep the computer awake, online, and both apps running.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = self.coordinator.errorMessage ?? self.coordinator.capabilityMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if self.coordinator.state.enabled || !self.coordinator.state.entries.isEmpty {
                if self.coordinator.state.enabled {
                    DisclosureGroup(L.zh ? "选择要守候的线程" : "Choose chats to watch") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L.zh ? "点击“确认守候”表示你确认该线程使用所选账号。账号切换后须重新选择。" : "Confirm that each chat uses the selected account. Select again after switching accounts.")
                                .foregroundStyle(.secondary)
                            ForEach(Array(self.coordinator.recentThreads.prefix(20)), id: \.threadID) { thread in
                                HStack(alignment: .top) {
                                    Text(thread.title).lineLimit(2)
                                    Spacer()
                                    if self.coordinator.state.watchedThreads[thread.threadID] != nil {
                                        Button(L.zh ? "取消" : "Cancel") { self.coordinator.unwatch(threadID: thread.threadID) }
                                    } else {
                                        Button(L.zh ? "确认守候" : "Watch") { self.coordinator.watch(threadID: thread.threadID) }
                                    }
                                }
                            }
                            Button(L.zh ? "刷新线程列表" : "Refresh chats") { Task { await self.coordinator.refreshThreads() } }
                        }.padding(.top, 8)
                    }
                }
                HStack {
                    Text(L.zh ? "恢复记录" : "Recovery activity").fontWeight(.medium)
                    Spacer()
                    Button(self.coordinator.isChecking ? (L.zh ? "检查中…" : "Checking…") : (L.zh ? "检查状态" : "Check status")) {
                        Task { await self.coordinator.checkNow() }
                    }
                    .disabled(self.coordinator.isChecking)
                }
                if self.coordinator.state.entries.isEmpty {
                    Text(L.zh ? "正在守候，尚未检测到新的额度中断" : "Watching for new quota interruptions")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(self.coordinator.state.entries.suffix(8).reversed())) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            Text(entry.title).fontWeight(.medium).lineLimit(2)
                            Spacer(minLength: 8)
                            if entry.status.canCancel {
                                Button(L.zh ? "取消守候" : "Cancel") { self.coordinator.cancel(entry.id) }
                                    .accessibilityIdentifier("codexbar.quota-resume.cancel.\(entry.id)")
                            }
                        }
                        Text(entry.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.status == .queued || entry.status == .uncertain || entry.status == .dispatching {
                            Text(L.zh ? "消息一旦提交，需在原线程停止；关闭守候不会撤回消息。" : "Stop submitted work in the original chat. Disabling watching does not retract a message.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if entry.status == .waiting, entry.nextCheckAt > Date() {
                            Text((L.zh ? "下次检查 " : "Next check ") + entry.nextCheckAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .font(.system(size: 11))
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("codexbar.quota-resume")
        .task { await self.coordinator.refreshThreads() }
    }

    var enabledBinding: Binding<Bool> {
        Binding(get: { self.coordinator.state.enabled }, set: { enabled in
            self.coordinator.configure(enabled: enabled,
                accountID: enabled ? self.selectedAccountID : self.coordinator.state.accountID)
        })
    }

    private var displayedAccount: TokenAccount? {
        let id = self.coordinator.state.enabled ? self.coordinator.state.accountID
            : (self.selectedAccountID ?? self.coordinator.desktopAccountID)
        return self.accounts.first(where: { $0.id == id })
    }
}
