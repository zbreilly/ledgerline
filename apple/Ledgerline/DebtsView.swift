import Charts
import SwiftUI

extension Debt: Identifiable {}
extension DebtGroup: Identifiable { public var id: String { key } }
extension PlanDebt: Identifiable {}
extension BalancePoint: Identifiable { public var id: String { ym } }
extension DebtSuggestion: Identifiable { public var id: String { "\(input.name)|\(input.paymentCents)|\(input.accountId ?? "")" } }

enum DebtKinds {
    static let all: [(String, String)] = [
        ("bnpl", "Buy now, pay later"), ("card", "Credit card"), ("installment", "Installment loan"),
        ("short_term", "Short-term loan"), ("auto", "Auto loan"), ("relief", "Debt relief program"), ("loan", "Other loan"),
    ]
    static func label(_ k: String) -> String { all.first { $0.0 == k }?.1 ?? k.capitalized }
}

enum Frequencies {
    static let all: [(String, String)] = [("once", "One time"), ("weekly", "Weekly"), ("biweekly", "Every 2 weeks"), ("monthly", "Monthly"), ("quarterly", "Quarterly"), ("semiannual", "Every 6 months"), ("yearly", "Yearly")]
    static func label(_ f: String) -> String { all.first { $0.0 == f }?.1 ?? f }
    static func short(_ f: String) -> String {
        ["once": " once", "weekly": "/wk", "biweekly": "/2 wk", "monthly": "/mo", "quarterly": "/qtr", "semiannual": "/6 mo", "yearly": "/yr"][f] ?? ""
    }
}

struct DebtsView: View {
    @Environment(AppModel.self) private var model
    @State private var debts: [Debt] = []
    @State private var groups: [DebtGroup] = []
    @State private var summary: DebtSummary?
    @State private var collapsed = Set<String>()
    @State private var editing: DebtDraft?
    @State private var deleting: Debt?
    @State private var showFind = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loaded && debts.isEmpty {
                    emptyState
                } else {
                    if let s = summary, s.unknownCount > 0 {
                        Label("\(s.unknownCount) debt\(s.unknownCount == 1 ? " needs" : "s need") a balance or payment before a payoff date can be estimated. Double-click one to fill it in.",
                              systemImage: "info.circle")
                            .foregroundStyle(Ink.secondary)
                    }
                    Text("By account").font(Font.app(.title3).weight(.semibold))
                    ForEach(groups) { groupCard($0) }
                    Text("All debts combined").font(Font.app(.title3).weight(.semibold)).padding(.top, 8)
                    if let s = summary { summaryRow(s) }
                    PayoffPlanPanel(revision: model.revision)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showFind = true } label: { Label("Find Debts", systemImage: "magnifyingglass") }.buttonStyle(.automatic)
                    .help("Find loans and payment plans in your transactions")
                Button { editing = DebtDraft() } label: { Label("Add Debt", systemImage: "plus") }.buttonStyle(.automatic)
            }
        }
        .task(id: model.reloadKey) { await load() }
        .onCommand(.newDebt, .findDebts) { command in
            if command == .findDebts { showFind = true } else { editing = DebtDraft() }
        }
        .sheet(item: $editing) { d in DebtEditor(draft: d).themedControls() }
        .sheet(isPresented: $showFind) { FindDebtsSheet().themedControls() }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                let id = deleting?.id ?? ""
                deleting = nil
                Task { await model.write { try $0.deleteDebt(id: id) } }
            }
        } message: {
            Text("Only the debt record is removed. Transactions stay as they are.")
        }
    }

    private func load() async {
        if let r = await model.run({ l in (try l.listDebts(), try l.debtSummary(), try l.debtGroups()) }) {
            debts = r.0
            summary = r.1
            groups = r.2
        }
        loaded = true
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "creditcard.and.123").font(.system(size: 40)).foregroundStyle(Ink.secondary)
            Text("No debts tracked yet").font(Font.app(.title3).weight(.semibold))
            Text("Ledgerline can find loan and payment-plan payments in your transactions (Affirm, Klarna, Zip, card accounts, and so on).")
                .foregroundStyle(Ink.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack {
                Button("Find Debts…") { showFind = true }.buttonStyle(.themedProminent)
                Button("Add Manually…") { editing = DebtDraft() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func summaryRow(_ s: DebtSummary) -> some View {
        HStack(spacing: 12) {
            StatCard(title: "Total Owed", value: Money.format(s.totalCents), detail: "\(s.count) debt\(s.count == 1 ? "" : "s")", tint: s.totalCents > 0 ? Color.negative : Color.themeText)
            StatCard(title: "Payments per Month", value: Money.format(s.monthlyPaymentsCents), detail: "Averaged across schedules")
            StatCard(title: "Average APR", value: s.weightedApr.map { String(format: "%.1f%%", $0) } ?? "—", detail: "Weighted by balance")
            StatCard(title: "Interest Ahead", value: Money.format(s.interestRemainingCents), detail: "At current payments")
            StatCard(title: "Debt-Free", value: s.debtFreeDate.map(Dates.monthTitleFromDate) ?? "—",
                     detail: s.unknownCount > 0 ? "Excludes \(s.unknownCount) without an estimate" : "At current payments")
        }
    }

    private func groupCard(_ g: DebtGroup) -> some View {
        let open = !collapsed.contains(g.key)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { collapsed.insert(g.key) } else { collapsed.remove(g.key) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").foregroundStyle(Ink.secondary).frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.name).font(Font.app(.headline))
                        Text(groupSubtitle(g)).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                    Spacer()
                    groupStat("Owed", g.unknownCount == g.debts.count && g.totalCents == 0 ? "Not set" : Money.format(g.totalCents), Color.negative)
                    groupStat("Per month", Money.format(g.monthlyCents), Color.themeText)
                    groupStat("Paid off", g.payoffDate.map(Dates.monthTitleFromDate) ?? (g.unknownCount > 0 ? "Needs info" : "—"), Color.themeText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(g.debts) { d in
                    Divider()
                    DebtRow(debt: d)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = DebtDraft(d) }
                        .contextMenu {
                            Button("Edit…") { editing = DebtDraft(d) }
                            Button("Delete…", role: .destructive) { deleting = d }
                        }
                }
            }
        }
        .padding(14)
        .surface(.panel, radius: 10)
    }

    private func groupSubtitle(_ g: DebtGroup) -> String {
        var parts = ["\(g.debts.count) \(g.debts.count == 1 ? "debt" : "debts")"]
        let kinds = Set(g.debts.map { DebtKinds.label($0.kind) })
        if kinds.count == 1, let k = kinds.first { parts.append(k) }
        switch (g.aprMin, g.aprMax) {
        case let (a?, b?) where a == b: parts.append(String(format: "%.2f%% APR", a))
        case let (a?, b?): parts.append(String(format: "%.1f–%.1f%% APR", a, b))
        default: break
        }
        if g.interestCents > 0 { parts.append("\(Money.format(g.interestCents)) interest ahead") }
        if g.unknownCount > 0 { parts.append("\(g.unknownCount) need\(g.unknownCount == 1 ? "s" : "") details") }
        return parts.joined(separator: " · ")
    }

    private func groupStat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            Text(value).font(Font.app(.body).weight(.semibold).monospacedDigit()).foregroundStyle(tint)
        }
        .frame(width: 120, alignment: .trailing)
    }
}

extension Dates {
    /// "2027-06-05" or "2027-06" -> "Jun 2027"
    static func monthTitleFromDate(_ s: String) -> String {
        guard let d = date(String(s.prefix(7)) + "-01") else { return s }
        return d.formatted(.dateTime.month(.abbreviated).year())
    }
}

struct DebtRow: View {
    let debt: Debt

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(debt.name).font(Font.app(.body).weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(DebtKinds.label(debt.kind))
                    if let a = debt.accountName, debt.balanceSource == "account" { Text("· follows \(a)") }
                    if debt.apr > 0 { Text(String(format: "· %.2f%% APR", debt.apr)) }
                }
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                if let orig = debt.originalCents, orig > 0, debt.currentBalanceCents <= orig {
                    ProgressView(value: Double(orig - debt.currentBalanceCents), total: Double(orig))
                        .frame(maxWidth: 220)
                        .help("\(Money.format(orig - debt.currentBalanceCents)) of \(Money.format(orig)) paid")
                }
            }
            .frame(minWidth: 240, alignment: .leading)
            Spacer()
            column("Balance") {
                if debt.payoff.status == "unknown" && debt.currentBalanceCents == 0 {
                    Text("Not set").foregroundStyle(Color.warning)
                } else {
                    Text(Money.format(debt.currentBalanceCents) + (debt.balanceIsEstimate ? "*" : ""))
                        .help(debt.balanceIsEstimate ? "Estimated from \(Money.format(debt.balanceCents)) on \(Dates.medium(debt.balanceAsOf)), plus interest, minus \(debt.paymentsSince) payment(s) found since" : "")
                }
            }
            column("Payment") {
                if debt.paymentCents > 0 {
                    Text(Money.format(debt.paymentCents) + Frequencies.short(debt.frequency))
                } else {
                    Text("Not set").foregroundStyle(Color.warning)
                }
            }
            column("Last paid") {
                if let last = debt.recentPayments.first {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Dates.short(last.date))
                        Text(Money.format(last.amountCents)).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                    .help("Recent payments:\n" + debt.recentPayments.map { "\(Dates.medium($0.date))  \(Money.format($0.amountCents))" }.joined(separator: "\n"))
                } else {
                    Text("None found").foregroundStyle(Ink.secondary)
                }
            }
            column("Next") {
                Text(debt.nextPaymentDate.map(Dates.short) ?? "—")
            }
            column("Payoff") {
                switch debt.payoff.status {
                case "paid_off": Text("Paid off").foregroundStyle(Color.positive)
                case "never": Text("Never").foregroundStyle(Color.negative).help("The payment doesn't cover the interest")
                case "ok":
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(debt.payoff.payoffDate.map(Dates.medium) ?? "—")
                        Text("\(debt.payoff.payments ?? 0) payments" + (debt.payoff.interestCents > 0 ? ", \(Money.format(debt.payoff.interestCents)) interest" : ""))
                            .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                default: Text("—").foregroundStyle(Ink.secondary)
                }
            }
            .frame(width: 190, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            content().monospacedDigit()
        }
        .frame(width: 110, alignment: .trailing)
    }
}

// MARK: - Payoff plan

struct PayoffPlanPanel: View {
    @Environment(AppModel.self) private var model
    let revision: Int
    @State private var strategy = "avalanche"
    @State private var extra: Int64 = 10_000
    @State private var plan: PlanResult?
    @State private var baseline: PlanResult?

    var body: some View {
        Panel(title: "Payoff plan") {
            HStack(spacing: 16) {
                Picker("Strategy", selection: $strategy) {
                    Text("Avalanche: highest APR first").tag("avalanche")
                    Text("Snowball: smallest balance first").tag("snowball")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Stepper("Extra each month: \(Money.format(extra))", value: $extra, in: 0...500_000, step: 2_500)
                    .monospacedDigit()
            }
            if let p = plan, let b = baseline {
                if p.debts.isEmpty {
                    Text("Add a balance and payment to at least one debt to see a plan.").foregroundStyle(Ink.secondary)
                } else {
                    HStack(spacing: 12) {
                        StatCard(title: "Debt-Free", value: p.never ? "Never" : (p.debtFreeMonth.map(Dates.monthTitleFromDate) ?? "—"),
                                 detail: "\(p.months) months", tint: p.never ? Color.negative : Color.positive)
                        StatCard(title: "Interest", value: Money.format(p.totalInterestCents),
                                 detail: savings(p, b))
                        StatCard(title: "Minimums Only", value: b.never ? "Never" : (b.debtFreeMonth.map(Dates.monthTitleFromDate) ?? "—"),
                                 detail: "\(Money.format(b.totalInterestCents)) interest")
                    }
                    chart(p, b)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Payoff order").font(Font.app(.subheadline).weight(.medium))
                        ForEach(p.debts) { d in
                            HStack {
                                Text("\(d.order).").monospacedDigit().foregroundStyle(Ink.secondary).frame(width: 24, alignment: .trailing)
                                Text(d.name).lineLimit(1)
                                Spacer()
                                Text(d.payoffMonth.map(Dates.monthTitleFromDate) ?? "—").monospacedDigit()
                                Text(Money.format(d.interestCents) + " interest").foregroundStyle(Ink.secondary).monospacedDigit().frame(width: 140, alignment: .trailing)
                            }
                            .font(Font.app(.callout))
                        }
                    }
                    if p.excluded > 0 {
                        Text("\(p.excluded) debt\(p.excluded == 1 ? " is" : "s are") left out because the balance or payment isn't set.")
                            .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                    Text("Every debt gets its minimum each month. The extra amount, plus minimums freed up by paid-off debts, goes to the next debt in order. Payments on other schedules are converted to a monthly average.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: "\(revision)|\(strategy)|\(extra)") { await load() }
    }

    private func savings(_ p: PlanResult, _ b: PlanResult) -> String {
        guard !b.never, !p.never else { return "" }
        let saved = b.totalInterestCents - p.totalInterestCents
        let months = Int(b.months) - Int(p.months)
        return saved > 0 || months > 0 ? "Saves \(Money.format(max(saved, 0))) and \(max(months, 0)) months" : "Same as minimums"
    }

    private func load() async {
        let s = strategy, e = extra
        if let r = await model.run({ l in (try l.payoffPlan(strategy: s, extraCents: e), try l.payoffPlan(strategy: "minimum", extraCents: 0)) }) {
            plan = r.0
            baseline = r.1
        }
    }

    private func chart(_ p: PlanResult, _ b: PlanResult) -> some View {
        Chart {
            ForEach(b.series) { pt in
                LineMark(x: .value("Month", Dates.date(pt.ym + "-01") ?? Date()), y: .value("Owed", Double(pt.balanceCents) / 100))
                    .foregroundStyle(by: .value("Plan", "Minimums only"))
            }
            ForEach(p.series) { pt in
                AreaMark(x: .value("Month", Dates.date(pt.ym + "-01") ?? Date()), y: .value("Owed", Double(pt.balanceCents) / 100))
                    .foregroundStyle(by: .value("Plan", "With extra"))
                    .opacity(0.35)
                LineMark(x: .value("Month", Dates.date(pt.ym + "-01") ?? Date()), y: .value("Owed", Double(pt.balanceCents) / 100))
                    .foregroundStyle(by: .value("Plan", "With extra"))
            }
        }
        .chartForegroundStyleScale(["Minimums only": Color.gray, "With extra": Color.positive])
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(Money.format(Int64(d * 100), compact: true)) } }
            }
        }
        .frame(height: 200)
    }
}

// MARK: - Add / edit

struct DebtDraft: Identifiable {
    var id = UUID().uuidString
    var debtId: String?
    var input = DebtInput(name: "", lender: "", kind: "installment", accountId: nil, balanceSource: "manual", balanceCents: 0,
                          balanceAsOf: Dates.string(Date()), originalCents: nil, apr: 0, paymentCents: 0, frequency: "monthly",
                          nextDue: nil, paymentsLeft: nil, matchKey: "", matchExactAmount: false, notes: "")

    init() {}
    init(_ d: Debt) {
        debtId = d.id
        input = DebtInput(name: d.name, lender: d.lender, kind: d.kind, accountId: d.accountId, balanceSource: d.balanceSource,
                          balanceCents: d.balanceCents, balanceAsOf: d.balanceAsOf, originalCents: d.originalCents, apr: d.apr,
                          paymentCents: d.paymentCents, frequency: d.frequency, nextDue: d.nextDue, paymentsLeft: d.paymentsLeft,
                          matchKey: d.matchKey, matchExactAmount: d.matchExactAmount, notes: d.notes)
    }
    init(suggestion s: DebtSuggestion) { input = s.input }
}

struct DebtEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: DebtDraft

    @State private var balance: Int64?
    @State private var original: Int64?
    @State private var payment: Int64?
    @State private var asOf = Date()
    @State private var hasNextDue = false
    @State private var nextDue = Date()
    @State private var hasPaymentsLeft = false
    @State private var paymentsLeft = 1
    @State private var aprText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.debtId == nil ? "Add debt" : "Edit debt").font(Font.app(.title3).weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $draft.input.name)
                    TextField("Lender", text: $draft.input.lender)
                    Picker("Type", selection: $draft.input.kind) {
                        ForEach(DebtKinds.all, id: \.0) { k in Text(k.1).tag(k.0) }
                    }
                }
                Section("Balance") {
                    Picker("Balance comes from", selection: $draft.input.balanceSource) {
                        Text("What I enter").tag("manual")
                        Text("A linked account").tag("account")
                    }
                    .pickerStyle(.segmented)
                    if draft.input.balanceSource == "account" {
                        Picker("Account", selection: $draft.input.accountId) {
                            Text("Choose…").tag(String?.none)
                            ForEach(model.accounts.filter { $0.kind == "credit" || $0.kind == "loan" }) { a in Text(a.name).tag(Optional(a.id)) }
                        }
                        Text("The balance follows the account, so it updates when you import.").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    } else {
                        MoneyField(title: "Amount owed", cents: $balance)
                        DatePicker("As of", selection: $asOf, displayedComponents: .date)
                        Text("Ledgerline adds interest since this date and subtracts the payments it finds.").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                    MoneyField(title: "Original amount (optional)", cents: $original)
                    TextField("APR %", text: $aprText, prompt: Text("0 for interest-free"))
                }
                Section("Payments") {
                    MoneyField(title: "Payment amount", cents: $payment)
                    Picker("How often", selection: $draft.input.frequency) {
                        ForEach(Frequencies.all, id: \.0) { f in Text(f.1).tag(f.0) }
                    }
                    Toggle("Next payment date", isOn: $hasNextDue)
                    if hasNextDue { DatePicker("Due", selection: $nextDue, displayedComponents: .date) }
                    Toggle("Fixed number of payments left", isOn: $hasPaymentsLeft)
                    if hasPaymentsLeft { Stepper("\(paymentsLeft) payment\(paymentsLeft == 1 ? "" : "s") left", value: $paymentsLeft, in: 1...600) }
                    TextField("Find payments by merchant", text: $draft.input.matchKey, prompt: Text("e.g. ZIP BEST"))
                    Toggle("Only count payments of exactly this amount", isOn: $draft.input.matchExactAmount)
                        .help("Use this when one lender has several loans, like Affirm")
                }
                Section {
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
        .frame(width: 520, height: 720)
        .onAppear {
            let i = draft.input
            balance = i.balanceCents > 0 ? i.balanceCents : nil
            original = i.originalCents
            payment = i.paymentCents > 0 ? i.paymentCents : nil
            asOf = Dates.date(i.balanceAsOf) ?? Date()
            hasNextDue = i.nextDue != nil
            nextDue = i.nextDue.flatMap(Dates.date) ?? Date()
            hasPaymentsLeft = i.paymentsLeft != nil
            paymentsLeft = Int(i.paymentsLeft ?? 1)
            aprText = i.apr > 0 ? String(format: "%g", i.apr) : ""
        }
    }

    private func save() {
        var i = draft.input
        i.balanceCents = abs(balance ?? 0)
        i.originalCents = original.map(abs)
        i.paymentCents = abs(payment ?? 0)
        i.balanceAsOf = Dates.string(asOf)
        i.nextDue = hasNextDue ? Dates.string(nextDue) : nil
        i.paymentsLeft = hasPaymentsLeft ? UInt32(paymentsLeft) : nil
        i.apr = Double(aprText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
        if i.balanceSource == "account" && i.accountId == nil {
            model.errorMessage = "Pick the account this debt follows, or switch the balance to \"What I enter\"."
            return
        }
        let id = draft.debtId
        let input = i
        Task {
            let ok = await model.write { l -> Bool in
                if let id { try l.updateDebt(id: id, input: input) } else { _ = try l.createDebt(input: input) }
                return true
            }
            if ok == true { dismiss() }
        }
    }
}

// MARK: - Find debts

struct FindDebtsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [DebtSuggestion]?
    @State private var chosen = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find debts").font(Font.app(.title3).weight(.semibold))
            Text("Repeating loan payments, card and loan accounts, and loans with an APR in their notes. Pick the ones to track; you can add balances and APRs afterward.")
                .foregroundStyle(Ink.secondary)
            if let list = suggestions {
                if list.isEmpty {
                    Text("Nothing new found. Everything detectable is already tracked.").foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    List(list) { s in
                        Toggle(isOn: Binding(get: { chosen.contains(s.id) }, set: { on in if on { chosen.insert(s.id) } else { chosen.remove(s.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(s.input.name).font(Font.app(.body).weight(.medium))
                                    Text(DebtKinds.label(s.input.kind)).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                                    Spacer()
                                    if s.input.paymentCents > 0 {
                                        Text(Money.format(s.input.paymentCents) + Frequencies.short(s.input.frequency)).monospacedDigit()
                                    }
                                }
                                Text(s.reason).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .frame(minHeight: 360)
                    Text("Tip: several Affirm loans can share one merchant name; each payment amount is listed as its own loan.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count)") { add() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680)
        .task {
            suggestions = await model.run { try $0.debtSuggestions() } ?? []
            chosen = Set(suggestions?.filter(\.recommended).map(\.id) ?? [])
        }
    }

    private func add() {
        let inputs = suggestions?.filter { chosen.contains($0.id) }.map(\.input) ?? []
        Task {
            if let n = await model.write({ l -> Int in
                for i in inputs { _ = try l.createDebt(input: i) }
                return inputs.count
            }) {
                model.notice = "Added \(n) debt\(n == 1 ? "" : "s"). Open each one to add its balance and APR."
                dismiss()
            }
        }
    }
}
