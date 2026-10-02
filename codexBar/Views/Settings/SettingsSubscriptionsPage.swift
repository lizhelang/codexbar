import SwiftUI

struct SettingsSubscriptionsPage: View {
    @ObservedObject private var store = SubscriptionRecordStore.shared
    @State private var draft = SubscriptionRecord()
    @State private var isEditing = false
    @State private var hasCustomRenewal = false
    @State private var errorMessage: String?
    @State private var deletingRecord: SubscriptionRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.zh ? "记录订阅或充值费用，供你核对实际支出。仅保存在这台 Mac，不会扣款或更改订阅。" : "Keep a local record of subscription and top-up costs. These records never charge or change a subscription.")
                .font(.system(size: 11))
                .foregroundStyle(SettingsPalette.muted)

            if let loadError = self.store.loadError {
                Text(loadError).font(.system(size: 11)).foregroundStyle(.orange)
            }
            if self.store.records.isEmpty && self.isEditing == false {
                Text(L.zh ? "尚无订阅记录" : "No subscription records yet")
                    .foregroundStyle(SettingsPalette.muted)
                    .padding(.vertical, 10)
            }
            ForEach(self.store.records) { record in
                self.recordRow(record)
            }
            if self.isEditing {
                self.editor
            } else {
                Button {
                    self.draft = SubscriptionRecord()
                    self.hasCustomRenewal = false
                    self.isEditing = true
                } label: {
                    Label(L.zh ? "添加订阅或充值" : "Add subscription or top-up", systemImage: "plus")
                }
            }
        }
        .alert(L.zh ? "删除这条费用记录？" : "Delete this cost record?", isPresented: Binding(
            get: { self.deletingRecord != nil },
            set: { if !$0 { self.deletingRecord = nil } }
        )) {
            Button(L.zh ? "删除" : "Delete", role: .destructive) {
                if let record = self.deletingRecord { try? self.store.remove(id: record.id) }
                self.deletingRecord = nil
            }
            Button(L.cancel, role: .cancel) { self.deletingRecord = nil }
        }
    }

    private func recordRow(_ record: SubscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(record.provider + (record.planName.isEmpty ? "" : " · " + record.planName))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(record.amount, format: .currency(code: record.currency))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Button(L.zh ? "编辑" : "Edit") {
                    self.draft = record
                    self.hasCustomRenewal = record.nextRenewal != nil
                    self.errorMessage = nil
                    self.isEditing = true
                }
                Button(role: .destructive) { self.deletingRecord = record } label: { Image(systemName: "trash") }
                    .accessibilityLabel(L.zh ? "删除记录" : "Delete record")
            }
            HStack {
                Text(record.kind == .topUp ? (L.zh ? "充值" : "Top-up") : self.intervalLabel(record))
                if let renewal = record.estimatedNextRenewal() {
                    Text(L.zh ? "下次续订" : "Next renewal")
                    Text(renewal, style: .date)
                }
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(SettingsPalette.muted)
            if !record.note.isEmpty {
                Text(record.note).font(.system(size: 10)).foregroundStyle(SettingsPalette.muted)
            }
            SettingsPalette.divider.frame(height: 1).padding(.top, 6)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L.zh ? "工具或服务" : "Tool or service", text: self.$draft.provider)
            TextField(L.zh ? "套餐名称" : "Plan name", text: self.$draft.planName)
            Picker(L.zh ? "类型" : "Type", selection: self.$draft.kind) {
                Text(L.zh ? "订阅" : "Subscription").tag(SubscriptionRecord.Kind.subscription)
                Text(L.zh ? "充值" : "Top-up").tag(SubscriptionRecord.Kind.topUp)
            }.pickerStyle(.segmented)
            HStack {
                TextField(L.zh ? "金额" : "Amount", value: self.$draft.amount, format: .number)
                SettingsSelectionField(L.zh ? "币种" : "Currency", selection: self.$draft.currency, options:
                    ["USD", "AUD", "CNY", "HKD", "TWD", "EUR", "GBP"].map { ($0, $0) }
                ).frame(width: 150)
            }
            DatePicker(L.zh ? "开始日期" : "Start date", selection: self.$draft.startDate, displayedComponents: .date)
            if self.draft.kind == .subscription {
                HStack {
                    Stepper(value: self.$draft.intervalCount, in: 1...120) {
                        Text(L.zh ? "每 \(self.draft.intervalCount)" : "Every \(self.draft.intervalCount)")
                    }
                    SettingsSelectionField(L.zh ? "周期" : "Interval", selection: self.$draft.interval, options: [
                        (.month, L.zh ? "月" : "Months"),
                        (.year, L.zh ? "年" : "Years"),
                    ]).frame(width: 160)
                }
                Toggle(L.zh ? "自动续订" : "Auto-renews", isOn: self.$draft.autoRenew)
                if self.draft.autoRenew {
                    Toggle(L.zh ? "指定下次续订日期" : "Set next renewal date", isOn: self.$hasCustomRenewal)
                    if self.hasCustomRenewal {
                        DatePicker(L.zh ? "下次续订" : "Next renewal", selection: Binding(
                            get: { self.draft.nextRenewal ?? self.draft.estimatedNextRenewal() ?? Date() },
                            set: { self.draft.nextRenewal = $0 }
                        ), displayedComponents: .date)
                    }
                }
            }
            TextField(L.zh ? "备注（可选）" : "Note (optional)", text: self.$draft.note)
            if let errorMessage = self.errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Button(L.zh ? "保存记录" : "Save record") { self.save() }.buttonStyle(.borderedProminent)
                Button(L.cancel) { self.isEditing = false; self.errorMessage = nil }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func save() {
        do {
            if !self.hasCustomRenewal || !self.draft.autoRenew || self.draft.kind == .topUp { self.draft.nextRenewal = nil }
            else if self.draft.nextRenewal == nil { self.draft.nextRenewal = self.draft.estimatedNextRenewal() }
            try self.store.save(self.draft)
            self.isEditing = false
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func intervalLabel(_ record: SubscriptionRecord) -> String {
        let unit = record.interval == .month ? (L.zh ? "月" : "month(s)") : (L.zh ? "年" : "year(s)")
        return L.zh ? "每 \(record.intervalCount) \(unit)" : "Every \(record.intervalCount) \(unit)"
    }
}
