import AppKit
import SwiftUI

struct SettingsDeviceSyncPage: View {
    @ObservedObject private var service = DeviceUsageSyncService.shared
    @State private var draft = DeviceUsageSyncConfiguration()
    @State private var pairingSecret = ""
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("多设备同步").font(.title2.weight(.semibold))
            Text("共享各设备的每日用量与工具统计。此页单独应用设置，默认仅保存在本机。")
                .font(.callout).foregroundStyle(.secondary)
            SettingsSelectionField("同步方式", selection: self.$draft.mode, options:
                DeviceUsageSyncMode.allCases.map { ($0, $0.title) }
            )
            LabeledContent("设备名称") { TextField("Mac", text: self.$draft.deviceName).frame(maxWidth: 280) }
            if self.draft.mode == .sharedFolder || self.draft.mode == .iCloudDrive {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(self.draft.mode == .iCloudDrive ? "iCloud Drive 文件夹" : "共享文件夹")
                        Spacer()
                        Button("选择文件夹…", action: self.chooseFolder)
                    }
                    Text(self.draft.folderPath.isEmpty ? "尚未选择" : self.draft.folderPath)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(self.draft.mode == .iCloudDrive
                         ? "在各设备选择同一个 iCloud Drive 文件夹。Codexbar 通过该目录同步，由系统负责上传与下载；没有独立云端账号。"
                         : "在各设备选择同一个共享目录。只读写其中的 Codexbar Usage Sync 子文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if self.draft.mode == .client {
                LabeledContent("Hub 地址") { TextField("http://192.168.1.10:23948", text: self.$draft.hubURL).frame(maxWidth: 280) }
                SecureField("配对密钥（留空沿用已保存密钥）", text: self.$pairingSecret)
                Text("支持 HTTPS；局域网地址可用 HTTP。请在可信网络内使用，配对密钥由 Hub 设备提供。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if self.draft.mode == .host {
                LabeledContent("监听端口") { TextField("23948", value: self.$draft.listenPort, format: .number.grouping(.never)).frame(width: 90) }
                Toggle("允许局域网设备连接", isOn: self.$draft.allowLANConnections)
                Text("关闭时仅监听 127.0.0.1。开启后监听本机 IPv4 网络；客户端仍必须提供配对密钥。")
                    .font(.caption).foregroundStyle(.secondary)
                if self.service.configuration.mode == .host {
                    HStack {
                        if let port = self.service.listeningPort { Text("Hub 端口：\(Int(port))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(self.copied ? "已复制配对密钥" : "复制配对密钥") {
                            guard let key = self.service.pairingSecretForUserCopy() else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key, forType: .string)
                            self.copied = true
                        }
                    }
                } else { Text("应用后生成此 Hub 的独立配对密钥。").font(.caption).foregroundStyle(.secondary) }
            }
            if self.draft.mode != .local {
                SettingsSelectionField("同步间隔", selection: self.$draft.syncIntervalSeconds, options: [
                    (30, "30 秒"), (60, "1 分钟"), (300, "5 分钟"), (900, "15 分钟"),
                ])
            }
            Divider()
            Text("仅同步日期、工具、Token 与费用汇总，不包含登录凭据、账户信息、订阅、会话标题或对话正文。Cursor API / CSV 属于账号级统计，保留在本机，避免跨设备重复相加。")
                .font(.caption).foregroundStyle(.secondary)
            Text("需要各设备运行 Codexbar。此同步协议不与 Token Monitor 的 Hub 互通。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Text(self.service.statusMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if self.service.configuration.mode != .local {
                    Button(self.service.isSyncing ? "同步中…" : "立即同步") { self.service.syncNow() }.disabled(self.service.isSyncing)
                }
                Button("应用同步设置", action: self.apply).buttonStyle(.borderedProminent)
            }
            if !self.service.remoteSnapshots.isEmpty {
                Divider()
                ForEach(self.service.remoteSnapshots) { device in
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(device.deviceName)
                        Spacer()
                        Text(device.isStale() ? "超过 24 小时未同步" : "已同步")
                            .font(.caption).foregroundStyle(device.isStale() ? .orange : .secondary)
                        Text(device.generatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            guard !self.didLoad else { return }
            self.draft = self.service.configuration
            self.didLoad = true
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择同步文件夹"
        if self.draft.mode == .iCloudDrive {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        }
        if panel.runModal() == .OK, let url = panel.url { self.draft.folderPath = url.resolvingSymlinksInPath().path }
    }

    private func apply() {
        do {
            try self.service.applyConfiguration(self.draft, pairingSecret: self.pairingSecret)
            self.pairingSecret = ""
            self.copied = false
            self.errorMessage = nil
        } catch { self.errorMessage = (error as? DeviceUsageSyncError)?.errorDescription ?? "无法保存同步设置。" }
    }
}
