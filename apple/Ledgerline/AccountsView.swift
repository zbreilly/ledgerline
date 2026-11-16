import Charts
import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var reports: [AccountReport] = []
    @State private var editing: AccountDraft?
    @State private var deleting: Account?

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MonthStepper(month: $model.month)
                    Spacer()
                    Button { editing = AccountDraft() } label: { Label("Add Account", systemImage: "plus") }
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(reports) { r in card(r) }
                }
                Text("Balances use the manual balance if you set one; otherwise they're the sum of the account's transactions. Monthly totals exclude transfers.")
                    .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            }
            .padding(20)
        }
        .task(id: model.reloadKey) { await load() }
        .onCommand(.newAccount) { _ in editing = AccountDraft() }
        .sheet(item: $editing) { d in AccountEditor(draft: d).themedControls() }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Account and Its Transactions", role: .destructive) {
                let id = deleting?.id ?? ""
                deleting = nil
                Task { await model.write { try $0.deleteAccount(id: id) } }
            }
        } message: {
            Text("This deletes \(deleting?.txCount ?? 0) transaction(s) too. It can't be undone.")
        }
    }

    private func load() async {
        let m = model.month
        reports = (await model.run { try $0.accountsReport(month: m) } ?? []).filter { !InvestmentKinds.isInvestment($0.account.kind) }
    }

    private func card(_ r: AccountReport) -> some View {
        let a = r.account
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: a.color)).frame(width: 10, height: 10)
                Text(a.name).font(Font.app(.headline))
                Text(kindLabel(a.kind)).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                Spacer()
                Menu {
                    Button("Edit…") { editing = AccountDraft(a) }
                    Button("Show Transactions") { model.activeAccount = a.id; model.showTransactions(TxPreset()) }
                    if a.balanceSet {
                        Button("Use Transaction Total as Balance") { Task { await model.write { try $0.clearAccountBalance(id: a.id) } } }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = a }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if (a.kind == "credit" || a.kind == "loan") && !a.balanceSet {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Balance not set").font(Font.app(.title2).weight(.semibold)).foregroundStyle(Color.warning)
                        Button("Set Balance…") { editing = AccountDraft(a, settingBalance: true) }
                    }
                    Text("Imports only show activity: \(Money.format(a.displayBalanceCents, sign: true)) net since your first import. Enter the balance from your statement or app.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(Money.format(a.displayBalanceCents)).font(Font.app(.title).weight(.semibold).monospacedDigit())
                        .foregroundStyle(a.displayBalanceCents < 0 ? Color.negative : Color.themeText)
                    if a.balanceSet { Text("manual").font(Font.app(.caption)).foregroundStyle(Ink.secondary) }
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("In this month").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    Text(Money.format(a.monthInCents)).monospacedDigit().foregroundStyle(Color.positive)
                }
                VStack(alignment: .leading) {
                    Text("Out this month").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    Text(Money.format(a.monthOutCents)).monospacedDigit()
                }
                VStack(alignment: .leading) {
                    Text("Transactions").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    Text("\(a.txCount)").monospacedDigit()
                }
            }
            Chart(r.series) { p in
                BarMark(x: .value("Month", p.ym), y: .value("Net", Double(p.netCents) / 100))
                    .foregroundStyle(p.netCents >= 0 ? Color.positive.opacity(0.7) : Color.pink.opacity(0.7))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 50)
            if let h = r.health {
                HStack(spacing: 12) {
                    if a.dueDay > 0 {
                        Label("Due day \(a.dueDay)", systemImage: "calendar")
                        if let pct = h.onTimePct { Label("\(pct)% on time (\(h.onTimeMonths)/\(h.totalMonths))", systemImage: "checkmark.seal") }
                    } else {
                        Label("Set a due day to track on-time payments", systemImage: "calendar.badge.exclamationmark")
                    }
                    if h.lateFeeCount > 0 {
                        Label("\(h.lateFeeCount) late fee(s), \(Money.format(h.lateFeeTotalCents))", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.negative)
                    }
                }
                .font(Font.app(.caption))
                .foregroundStyle(Ink.secondary)
            }
            if let last = a.lastActivity {
                Text("Last activity \(Dates.medium(last))").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            }
        }
        .padding(14)
        .surface(.panel, radius: 10)
    }

    private func kindLabel(_ k: String) -> String {
        ["checking": "Checking", "savings": "Savings", "cash": "Cash", "credit": "Credit card", "loan": "Loan"][k] ?? InvestmentKinds.label(k)
    }
}

struct AccountDraft: Identifiable {
    var id = UUID().uuidString
    var accountId: String?
    var name = ""
    var institution = ""
    var kind = "checking"
    var color = Color(hex: "#6d7cff")
    var dueDay = 0
    var setBalance = false
    var balance: Int64? = 0

    init() {}
    init(_ a: Account, settingBalance: Bool = false) {
        accountId = a.id; name = a.name; institution = a.institution; kind = a.kind; color = Color(hex: a.color)
        dueDay = Int(a.dueDay); setBalance = a.balanceSet || settingBalance
        balance = a.balanceSet ? a.displayBalanceCents : nil
    }
}

struct AccountEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: AccountDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.accountId == nil ? "New account" : "Edit account").font(Font.app(.title3).weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $draft.name)
                TextField("Institution", text: $draft.institution)
                Picker("Type", selection: $draft.kind) {
                    Text("Checking").tag("checking")
                    Text("Savings").tag("savings")
                    Text("Cash").tag("cash")
                    Text("Credit card").tag("credit")
                    Text("Loan").tag("loan")
                }
                TriangleColorField(label: "Color", selection: $draft.color)
                if draft.kind == "credit" || draft.kind == "loan" {
                    Stepper(draft.dueDay == 0 ? "Payment due day: not set" : "Payment due day: \(draft.dueDay)", value: $draft.dueDay, in: 0...31)
                }
                Toggle("Set balance manually", isOn: $draft.setBalance)
                if draft.setBalance {
                    MoneyField(title: "Balance", cents: $draft.balance)
                    Text("Debts are negative (for example −1250.00).").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 440)
    }

    private func save() {
        let d = draft
        let hex = d.color.hexString
        Task {
            let ok = await model.write { l -> Bool in
                if let id = d.accountId {
                    try l.updateAccount(id: id, patch: AccountPatch(name: d.name, institution: d.institution, kind: d.kind,
                                                                     balanceCents: d.setBalance ? (d.balance ?? 0) : nil, color: hex,
                                                                     archived: nil, dueDay: UInt32(d.dueDay)))
                    if !d.setBalance { try l.clearAccountBalance(id: id) }
                } else {
                    let id = try l.createAccount(input: NewAccount(name: d.name, institution: d.institution, kind: d.kind,
                                                                   balanceCents: d.balance ?? 0, color: hex, dueDay: UInt32(d.dueDay)))
                    if d.setBalance {
                        try l.updateAccount(id: id, patch: AccountPatch(name: nil, institution: nil, kind: nil, balanceCents: d.balance ?? 0,
                                                                         color: nil, archived: nil, dueDay: nil))
                    }
                }
                return true
            }
            if ok == true { dismiss() }
        }
    }
}
