import Charts
import SwiftUI

extension Investment: Identifiable {}
extension ValuePoint: Identifiable {}
extension NetWorthLine: Identifiable { public var id: String { group + "|" + name } }

enum InvestmentKinds {
    static let all: [(String, String)] = [("retirement", "Retirement (401(k), IRA)"), ("brokerage", "Brokerage"), ("hsa", "HSA")]
    static func isInvestment(_ k: String) -> Bool { ["brokerage", "retirement", "hsa"].contains(k) }
    static func label(_ k: String) -> String {
        ["retirement": "Retirement", "brokerage": "Brokerage", "hsa": "HSA"][k] ?? k.capitalized
    }
}

struct InvestmentsView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Investment] = []
    @State private var loaded = false
    @State private var editing: InvestmentDraft?
    @State private var updating: Investment?
    @State private var deleting: Investment?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loaded && items.isEmpty {
                    empty
                } else {
                    summary
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16)], spacing: 16) {
                        ForEach(items) { card($0) }
                    }
                    Text("Investment values don't come from imports. Update them from your statements whenever you like; each update is kept so you can see the trend.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button { editing = InvestmentDraft() } label: { Label("Add Investment Account", systemImage: "plus") }.buttonStyle(.automatic)
            }
        }
        .task(id: model.revision) {
            items = await model.run { try $0.listInvestments() } ?? []
            loaded = true
        }
        .onCommand(.newInvestment) { _ in editing = InvestmentDraft() }
        .sheet(item: $editing) { d in InvestmentEditor(draft: d).themedControls() }
        .sheet(item: $updating) { inv in UpdateValueSheet(investment: inv).themedControls() }
        .confirmationDialog("Remove \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) {
                let id = deleting?.id ?? ""
                deleting = nil
                Task { await model.write { try $0.deleteAccount(id: id) } }
            }
        } message: {
            Text("This removes the account and its value history from Ledgerline.")
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 40)).foregroundStyle(Ink.secondary)
            Text("No investment accounts yet").font(Font.app(.title3).weight(.semibold))
            Text("Add your 401(k), IRA, brokerage, or HSA accounts. They count toward your net worth on the Dashboard.")
                .foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            Button("Add Investment Account…") { editing = InvestmentDraft() }.buttonStyle(.themedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var summary: some View {
        let total = items.reduce(Int64(0)) { $0 + $1.valueCents }
        let retirement = items.filter { $0.kind == "retirement" }.reduce(Int64(0)) { $0 + $1.valueCents }
        let taxable = items.filter { $0.kind == "brokerage" }.reduce(Int64(0)) { $0 + $1.valueCents }
        return HStack(spacing: 12) {
            StatCard(title: "Total Invested", value: Money.format(total), detail: "\(items.count) account\(items.count == 1 ? "" : "s")")
            StatCard(title: "Retirement", value: Money.format(retirement))
            StatCard(title: "Brokerage", value: Money.format(taxable))
            StatCard(title: "Change Since First Entry", value: Money.format(items.reduce(Int64(0)) { $0 + $1.changeCents }, sign: true))
        }
    }

    private func card(_ inv: Investment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: inv.color)).frame(width: 10, height: 10)
                Text(inv.name).font(Font.app(.headline)).lineLimit(1)
                Spacer()
                Menu {
                    Button("Update Value…") { updating = inv }
                    Button("Edit Details…") { editing = InvestmentDraft(inv) }
                    Divider()
                    Button("Remove…", role: .destructive) { deleting = inv }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Text([inv.accountLabel.isEmpty ? InvestmentKinds.label(inv.kind) : inv.accountLabel, inv.institution,
                  inv.accountLast4.isEmpty ? nil : "…\(inv.accountLast4)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(Money.format(inv.valueCents)).font(Font.app(.title).weight(.semibold).monospacedDigit())
                Text(inv.valueAsOf.map { "as of \(Dates.medium($0))" } ?? "no value yet").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                Spacer()
                Button("Update Value") { updating = inv }
            }
            if inv.history.count >= 2 {
                Chart(inv.history) { p in
                    LineMark(x: .value("Date", Dates.date(p.date) ?? Date()), y: .value("Value", Double(p.valueCents) / 100))
                    PointMark(x: .value("Date", Dates.date(p.date) ?? Date()), y: .value("Value", Double(p.valueCents) / 100))
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Money.format(Int64(d * 100), compact: true)) } }
                    }
                }
                .frame(height: 110)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if !inv.employer.isEmpty { row("Employer", inv.employer) }
                if !inv.allocation.isEmpty { row("Invested in", inv.allocation) }
                if let pct = inv.contributionPct { row("Contribution", String(format: "%g%% of pay", pct)) }
                if !inv.employerMatch.isEmpty { row("Employer match", inv.employerMatch) }
                if !inv.notes.isEmpty { row("Notes", inv.notes) }
            }
            .font(Font.app(.callout))
        }
        .padding(14)
        .surface(.panel, radius: 10)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Ink.secondary)
            Text(v).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InvestmentDraft: Identifiable {
    var id = UUID().uuidString
    var investmentId: String?
    var input = InvestmentInput(name: "", institution: "", kind: "retirement", color: "#34d399", accountLabel: "", employer: "",
                                allocation: "", contributionPct: nil, employerMatch: "", accountLast4: "", notes: "",
                                valueCents: nil, valueAsOf: nil)
    init() {}
    init(_ i: Investment) {
        investmentId = i.id
        input = InvestmentInput(name: i.name, institution: i.institution, kind: i.kind, color: i.color, accountLabel: i.accountLabel,
                                employer: i.employer, allocation: i.allocation, contributionPct: i.contributionPct, employerMatch: i.employerMatch,
                                accountLast4: i.accountLast4, notes: i.notes, valueCents: nil, valueAsOf: nil)
    }
}

struct InvestmentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: InvestmentDraft
    @State private var value: Int64?
    @State private var asOf = Date()
    @State private var pctText = ""
    @State private var color = Color.positive

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.investmentId == nil ? "Add investment account" : "Edit investment account").font(Font.app(.title3).weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $draft.input.name, prompt: Text("e.g. Acme 401(k)"))
                    Picker("Type", selection: $draft.input.kind) {
                        ForEach(InvestmentKinds.all, id: \.0) { k in Text(k.1).tag(k.0) }
                    }
                    TextField("Account type", text: $draft.input.accountLabel, prompt: Text("401(k), Roth IRA, Individual…"))
                    TextField("Institution", text: $draft.input.institution, prompt: Text("e.g. Vanguard"))
                    TextField("Last 4 of account number", text: $draft.input.accountLast4)
                    TriangleColorField(label: "Color", selection: $color)
                }
                if draft.investmentId == nil {
                    Section("Current value") {
                        MoneyField(title: "Value", cents: $value)
                        DatePicker("As of", selection: $asOf, displayedComponents: .date)
                    }
                }
                Section("Details (optional)") {
                    TextField("Employer", text: $draft.input.employer)
                    TextField("Invested in", text: $draft.input.allocation, prompt: Text("e.g. Freedom Index 2050 — 100%"))
                    TextField("Contribution % of pay", text: $pctText)
                    TextField("Employer match", text: $draft.input.employerMatch, prompt: Text("e.g. 100% of first 4%"))
                    TextField("Notes", text: $draft.input.notes, axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
                    .disabled(draft.input.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480, height: 640)
        .onAppear {
            pctText = draft.input.contributionPct.map { String(format: "%g", $0) } ?? ""
            color = Color(hex: draft.input.color)
        }
    }

    private func save() {
        var i = draft.input
        i.color = color.hexString
        i.contributionPct = Double(pctText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        if draft.investmentId == nil {
            i.valueCents = value ?? 0
            i.valueAsOf = Dates.string(asOf)
        }
        let id = draft.investmentId
        let input = i
        Task {
            let ok = await model.write { l -> Bool in
                if let id { try l.updateInvestment(id: id, input: input) } else { _ = try l.createInvestment(input: input) }
                return true
            }
            if ok == true { dismiss() }
        }
    }
}

struct UpdateValueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let investment: Investment
    @State private var value: Int64?
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update \(investment.name)").font(Font.app(.headline))
            Form {
                MoneyField(title: "Value", cents: $value)
                DatePicker("As of", selection: $date, displayedComponents: .date)
                TextField("Note (optional)", text: $note, prompt: Text("e.g. Q4 statement"))
            }
            .formStyle(.grouped)
            if !investment.history.isEmpty {
                Text("History").font(Font.app(.subheadline).weight(.medium))
                ForEach(investment.history.reversed()) { p in
                    HStack {
                        Text(Dates.medium(p.date)).monospacedDigit()
                        Text(p.note).foregroundStyle(Ink.secondary).lineLimit(1)
                        Spacer()
                        Text(Money.format(p.valueCents)).monospacedDigit()
                        Button(role: .destructive) {
                            let id = p.id
                            Task { await model.write { try $0.deleteInvestmentValue(entryId: id) }; dismiss() }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete this entry")
                    }
                    .font(Font.app(.callout))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let id = investment.id, v = value ?? 0, d = Dates.string(date), n = note
                    Task {
                        let ok = await model.write { l -> Bool in
                            try l.recordInvestmentValue(id: id, date: d, valueCents: v, note: n)
                            return true
                        }
                        if ok == true { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
                .disabled(value == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { value = investment.valueCents }
    }
}
