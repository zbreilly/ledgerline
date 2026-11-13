import SwiftUI

extension Recurring: Identifiable {}
extension CalendarDay: Identifiable { public var id: String { date } }
extension CalendarEvent: Identifiable { public var id: String { "\(sourceId)|\(date)" } }
extension PayPeriod: Identifiable { public var id: String { start } }
extension RecurringSuggestion: Identifiable {
    public var id: String { "\(input.matchKey)|\(input.amountCents)|\(input.frequency)|\(input.name)" }
}

extension CalendarEvent {
    var color: Color {
        switch kind {
        case "income": Color.positive
        case "debt": Color.warning
        default: .pink
        }
    }

    var statusSymbol: String? {
        switch status {
        case "paid": "checkmark.circle.fill"
        case "missed": "exclamationmark.circle"
        case "unknown": "questionmark.circle"
        default: nil
        }
    }

    var statusHelp: String {
        switch status {
        case "paid": "Found in transactions" + (actualCents.map { " (\(Money.format($0)))" } ?? "")
        case "missed": "Not found in transactions"
        case "unknown": "After your last import"
        default: "Upcoming"
        }
    }
}

struct CashFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "month"

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Month").tag("month")
                Text("Pay Periods").tag("periods")
                Text("Recurring").tag("recurring")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case "periods": PayPeriodsTab()
            case "recurring": RecurringTab()
            default: MonthTab(showRecurring: { tab = "recurring" })
            }
        }
        .onAppear(perform: showTabForCommand)
        .onChange(of: model.pendingCommand) { _, _ in showTabForCommand() }
    }

    /// A menu command for one of the tabs: switch to that tab, which then carries it out.
    private func showTabForCommand() {
        switch model.pendingCommand {
        case .newRecurring, .findRecurring: tab = "recurring"
        case .cashBalances: tab = "month"
        default: break
        }
    }
}

// MARK: - Month

struct MonthTab: View {
    @Environment(AppModel.self) private var model
    let showRecurring: () -> Void
    @State private var cal: CalendarMonth?
    @State private var selected: String?
    @State private var showBalances = false
    @State private var showFind = false
    @State private var flex: FlexibleBudgets?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    MonthStepper(month: $model.month)
                    Spacer()
                    if let c = cal, c.paychecks >= 3 {
                        Label("3-paycheck month", systemImage: "star.fill").foregroundStyle(Color.positive)
                    }
                }
                if let c = cal {
                    banners(c)
                    stats(c)
                    grid(c)
                    if let sel = selected, let day = c.days.first(where: { $0.date == sel }) { dayDetail(day) }
                    if let f = flex, !f.lines.isEmpty { flexPanel(f) }
                    if !c.threePaycheckMonths.isEmpty {
                        Text("Months with three paychecks in the next year: " + c.threePaycheckMonths.map(Dates.monthTitle).joined(separator: ", "))
                            .font(Font.app(.callout)).foregroundStyle(Ink.secondary)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .task(id: model.reloadKey) { await load() }
        .onCommand(.cashBalances) { _ in showBalances = true }
        .sheet(isPresented: $showBalances) { CashBalancesSheet().themedControls() }
        .sheet(isPresented: $showFind) { FindRecurringSheet().themedControls() }
    }

    private func load() async {
        let m = model.month
        cal = await model.run { try $0.calendar(month: m) }
        flex = await model.run { try $0.flexibleBudgets() }
        if selected == nil || !(cal?.days.contains { $0.date == selected } ?? false) {
            selected = cal?.today.hasPrefix(m) == true ? cal?.today : nil
        }
    }

    private func flexPanel(_ f: FlexibleBudgets) -> some View {
        Panel(title: "Day-to-day spending in the projection",
              trailing: AnyView(Text("\(Money.format(f.monthlyCents)) a month").monospacedDigit().foregroundStyle(Ink.secondary))) {
            Text("The projection spreads each budget evenly across the month, minus what's already a scheduled bill or debt payment. This month only counts what's left of each budget.")
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            ForEach(f.lines, id: \.name) { l in
                HStack {
                    Circle().fill(.purple.opacity(0.7)).frame(width: 7, height: 7)
                    Text(l.name).lineLimit(1)
                    if l.scheduledCents > 0 {
                        Text("budget \(Money.format(l.budgetCents)) − \(Money.format(l.scheduledCents)) scheduled").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                    Spacer()
                    Text("\(Money.format(l.remainingThisMonthCents)) left this month").font(Font.app(.caption)).foregroundStyle(l.remainingThisMonthCents == 0 ? Color.warning : Color.themeSecondary)
                    Text(Money.format(l.monthlyCents) + "/mo").monospacedDigit().frame(width: 100, alignment: .trailing)
                }
                .font(Font.app(.callout))
            }
        }
    }

    @ViewBuilder private func banners(_ c: CalendarMonth) -> some View {
        if c.mainIncomeName == nil {
            HStack {
                Label("Add your paycheck and regular bills to see what's coming.", systemImage: "calendar.badge.plus")
                Spacer()
                Button("Find from Transactions…") { showFind = true }.buttonStyle(.themedProminent)
            }
            .padding(12)
            .background(Color.info.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        if c.balanceNeedsSetup {
            HStack {
                Label("Projected cash starts at \(Money.format(c.startBalanceCents)) because a cash account has no real balance set. Enter today's balance for an accurate projection.",
                      systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Set Balances…") { showBalances = true }
            }
            .padding(12)
            .background(Color.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func stats(_ c: CalendarMonth) -> some View {
        HStack(spacing: 12) {
            StatCard(title: "Paychecks", value: "\(c.paychecks)", detail: c.mainIncomeName ?? "No paycheck set", tint: c.paychecks >= 3 ? Color.positive : Color.themeText)
            StatCard(title: "Income", value: Money.format(c.incomeCents), tint: Color.positive)
            StatCard(title: "Bills", value: Money.format(c.billsCents))
            StatCard(title: "Debt Payments", value: Money.format(c.debtCents), tint: Color.warning)
            StatCard(title: "Day-to-Day Spending", value: Money.format(c.flexibleCents),
                     detail: c.month == String(c.today.prefix(7)) ? "Rest of this month, from budgets" : "From budgets, spread daily", tint: .purple)
            StatCard(title: "Lowest Projected Cash", value: c.lowestBalanceCents.map { Money.format($0) } ?? "—",
                     detail: c.lowestDate.map { "on \(Dates.medium($0))" } ?? "Past month",
                     tint: (c.lowestBalanceCents ?? 0) < 0 ? Color.negative : Color.themeText)
        }
    }

    private func grid(_ c: CalendarMonth) -> some View {
        let first = Dates.date(c.days.first?.date ?? "") ?? Date()
        let lead = Calendar(identifier: .gregorian).component(.weekday, from: first) - 1
        let cells: [CalendarDay?] = Array(repeating: nil, count: lead) + c.days.map { Optional($0) }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) { d in
                    Text(d).font(Font.app(.caption).weight(.medium)).foregroundStyle(Ink.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        DayCell(day: day, isToday: day.date == c.today, isSelected: day.date == selected)
                            .onTapGesture { selected = day.date }
                    } else {
                        Color.clear.frame(height: 108)
                    }
                }
            }
        }
    }

    private func dayDetail(_ day: CalendarDay) -> some View {
        Panel(title: Dates.date(day.date).map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day()) } ?? day.date,
              trailing: AnyView(day.projectedBalanceCents.map { Text("Projected cash \(Money.format($0))").monospacedDigit().foregroundStyle($0 < 0 ? Color.negative : Color.themeSecondary) })) {
            if day.events.isEmpty {
                Text("Nothing scheduled.").foregroundStyle(Ink.secondary)
            }
            ForEach(day.events) { e in
                HStack {
                    Circle().fill(e.color).frame(width: 8, height: 8)
                    Text(e.name.squished).lineLimit(1)
                    if !e.affectsCash { Text("on card").font(Font.app(.caption)).foregroundStyle(Ink.secondary) }
                    if e.countsInMonth != String(e.date.prefix(7)) {
                        Text("counts in \(Dates.monthTitle(e.countsInMonth))").font(Font.app(.caption)).foregroundStyle(Color.info)
                    }
                    Spacer()
                    if let s = e.statusSymbol {
                        Image(systemName: s).foregroundStyle(e.status == "paid" ? Color.positive : Color.warning).help(e.statusHelp)
                    }
                    Text(e.status.capitalized).font(Font.app(.caption)).foregroundStyle(Ink.secondary).frame(width: 70, alignment: .leading)
                    AmountText(cents: e.actualCents ?? e.amountCents).frame(width: 100, alignment: .trailing)
                }
                .font(Font.app(.callout))
            }
            Button("Manage Recurring Items…", action: showRecurring).buttonStyle(.link)
        }
    }
}

struct DayCell: View {
    let day: CalendarDay
    let isToday: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(Int(day.date.suffix(2)) ?? 0)")
                    .font(Font.app(.callout).weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : Color.themeText)
                    .padding(.horizontal, isToday ? 6 : 0)
                    .background(isToday ? Capsule().fill(Color.themeAccent) : nil)
                Spacer()
                if day.events.contains(where: { $0.kind == "income" }) {
                    Image(systemName: "dollarsign.circle.fill").foregroundStyle(Color.positive).font(Font.app(.caption))
                }
            }
            ForEach(day.events.prefix(3)) { e in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(e.color).frame(width: 3, height: 11)
                    Text(e.name.squished).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Font.app(.caption2))
                .opacity(e.status == "paid" ? 0.55 : 1)
            }
            if day.events.count > 3 {
                Text("+\(day.events.count - 3) more").font(Font.app(.caption2)).foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 0)
            if let b = day.projectedBalanceCents {
                Text(Money.format(b, compact: true))
                    .font(Font.app(.caption2).monospacedDigit())
                    .foregroundStyle(b < 0 ? Color.negative : Color.themeSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
        .surface(.card, radius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.themeAccent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

// MARK: - Pay periods

struct PayPeriodsTab: View {
    @Environment(AppModel.self) private var model
    @State private var periods: [PayPeriod]?
    @State private var expanded = Set<String>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Each period runs from a payday to the day before the next one. Leftover is the paycheck minus bills and debt payments due in that period (charges on credit cards aren't counted) and the day-to-day budgets (groceries, dining, fuel, …) spread over its days.")
                    .font(Font.app(.callout)).foregroundStyle(Ink.secondary)
                if let ps = periods {
                    if ps.isEmpty {
                        Text("Add your paycheck on the Recurring tab to see pay periods.").foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    ForEach(ps) { p in card(p) }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .task(id: model.revision) {
            periods = await model.run { try $0.payPeriods(count: 6) }
            if let cur = periods?.first(where: \.isCurrent) { expanded.insert(cur.id) }
        }
    }

    private func card(_ p: PayPeriod) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(Dates.medium(p.start)) – \(Dates.medium(p.end))").font(Font.app(.headline))
                if p.isCurrent { Text("Now").font(Font.app(.caption).bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.info.opacity(0.2), in: Capsule()) }
                Spacer()
                Button(expanded.contains(p.id) ? "Hide Details" : "Show \(p.events.count) Items") {
                    if expanded.contains(p.id) { expanded.remove(p.id) } else { expanded.insert(p.id) }
                }
                .buttonStyle(.link)
            }
            HStack(spacing: 18) {
                metric("Paycheck", p.paycheckCents, Color.positive)
                if p.otherIncomeCents > 0 { metric("Other income", p.otherIncomeCents, Color.positive) }
                metric("Bills", -p.billsCents, Color.themeText)
                metric("Debt payments", -p.debtCents, Color.warning)
                metric("Day-to-day budgets", -p.flexibleCents, .purple)
                Divider().frame(height: 32)
                metric("Leftover", p.leftoverCents, p.leftoverCents >= 0 ? Color.positive : Color.negative, bold: true)
                if let end = p.endingBalanceCents { metric("Cash at end", end, end >= 0 ? Color.themeText : Color.negative) }
            }
            if p.paycheckCents > 0 {
                GeometryReader { g in
                    let total = Double(p.paycheckCents + p.otherIncomeCents)
                    HStack(spacing: 0) {
                        Rectangle().fill(.pink.opacity(0.7)).frame(width: g.size.width * min(Double(p.billsCents) / total, 1))
                        Rectangle().fill(Color.warning.opacity(0.8)).frame(width: g.size.width * min(Double(p.debtCents) / total, 1))
                        Rectangle().fill(.purple.opacity(0.6)).frame(width: g.size.width * min(Double(p.flexibleCents) / total, 1))
                        Rectangle().fill(Color.positive.opacity(0.35))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
            }
            if expanded.contains(p.id) {
                ForEach(p.events) { e in
                    HStack {
                        Text(Dates.short(e.date)).foregroundStyle(Ink.secondary).frame(width: 56, alignment: .leading)
                        Circle().fill(e.color).frame(width: 7, height: 7)
                        Text(e.name.squished).lineLimit(1)
                        if !e.affectsCash { Text("on card").font(Font.app(.caption)).foregroundStyle(Ink.secondary) }
                    if e.countsInMonth != String(e.date.prefix(7)) {
                        Text("counts in \(Dates.monthTitle(e.countsInMonth))").font(Font.app(.caption)).foregroundStyle(Color.info)
                    }
                        Spacer()
                        if let s = e.statusSymbol { Image(systemName: s).foregroundStyle(e.status == "paid" ? Color.positive : Color.warning).help(e.statusHelp) }
                        AmountText(cents: e.actualCents ?? e.amountCents).frame(width: 100, alignment: .trailing)
                    }
                    .font(Font.app(.callout))
                }
            }
        }
        .padding(14)
        .surface(.panel, radius: 10)
    }

    private func metric(_ title: String, _ cents: Int64, _ tint: Color, bold: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            Text(Money.format(cents)).font(bold ? Font.app(.title3).weight(.semibold).monospacedDigit() : Font.app(.body).monospacedDigit()).foregroundStyle(tint)
        }
    }
}

// MARK: - Recurring list

struct RecurringTab: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Recurring] = []
    @State private var selection = Set<String>()
    @State private var editing: RecurringDraft?
    @State private var showFind = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Paychecks and bills that repeat. The calendar and pay periods are built from these and your debts.")
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Button("Find from Transactions…") { showFind = true }
                Button { editing = RecurringDraft() } label: { Label("Add", systemImage: "plus") }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            Table(items, selection: $selection) {
                TableColumn("On") { r in
                    Toggle("", isOn: Binding(get: { r.active }, set: { on in toggle(r, on) })).labelsHidden()
                }
                .width(30)
                TableColumn("Name") { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name.squished).lineLimit(1)
                        Text([r.categoryName, r.accountName.map { $0 + (r.affectsCash ? "" : " (card)") }].compactMap { $0 }.joined(separator: " · "))
                            .font(Font.app(.caption)).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                }
                TableColumn("Amount") { r in
                    Text((r.kind == "income" ? "+" : "−") + Money.format(r.amountCents)).monospacedDigit()
                        .foregroundStyle(r.kind == "income" ? Color.positive : Color.themeText)
                }
                .width(100)
                TableColumn("Repeats") { r in Text(Frequencies.label(r.frequency)) }.width(110)
                TableColumn("Next") { r in Text(r.nextDate.map(Dates.medium) ?? "—").monospacedDigit() }.width(110)
                TableColumn("Last seen") { r in Text(r.lastSeen.map(Dates.medium) ?? "—").foregroundStyle(Ink.secondary).monospacedDigit() }.width(110)
                TableColumn("Per month") { r in Text(Money.format(r.monthlyCents)).foregroundStyle(Ink.secondary).monospacedDigit() }.width(90)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let r = items.first(where: { $0.id == id }) {
                    Button("Edit…") { editing = RecurringDraft(r) }
                    Button("Delete", role: .destructive) { Task { await model.write { try $0.deleteRecurring(id: id) } } }
                }
            } primaryAction: { ids in
                if let id = ids.first, let r = items.first(where: { $0.id == id }) { editing = RecurringDraft(r) }
            }
            let income = items.filter { $0.active && $0.kind == "income" }.reduce(Int64(0)) { $0 + $1.monthlyCents }
            let bills = items.filter { $0.active && $0.kind == "bill" }.reduce(Int64(0)) { $0 + $1.monthlyCents }
            HStack(spacing: 16) {
                Text("Per month: income \(Money.format(income))").foregroundStyle(Color.positive)
                Text("bills \(Money.format(bills))")
                Text("difference \(Money.format(income - bills, sign: true))").foregroundStyle(Ink.secondary)
                Spacer()
                Text("Debt payments are managed on the Debt page.").foregroundStyle(Ink.secondary)
            }
            .font(Font.app(.callout).monospacedDigit())
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .task(id: model.revision) { items = await model.run { try $0.listRecurring() } ?? [] }
        .onCommand(.newRecurring, .findRecurring) { command in
            if command == .findRecurring { showFind = true } else { editing = RecurringDraft() }
        }
        .sheet(item: $editing) { d in RecurringEditor(draft: d).themedControls() }
        .sheet(isPresented: $showFind) { FindRecurringSheet().themedControls() }
    }

    private func toggle(_ r: Recurring, _ on: Bool) {
        var i = RecurringDraft(r).input
        i.active = on
        let input = i
        Task { await model.write { try $0.updateRecurring(id: r.id, input: input) } }
    }
}

struct RecurringDraft: Identifiable {
    var id = UUID().uuidString
    var recurringId: String?
    var input = RecurringInput(name: "", kind: "bill", amountCents: 0, frequency: "monthly", anchorDate: Dates.string(Date()),
                               matchKey: "", matchExactAmount: false, categoryId: nil, accountId: nil, active: true, notes: "")
    init() {}
    init(_ r: Recurring) {
        recurringId = r.id
        input = RecurringInput(name: r.name, kind: r.kind, amountCents: r.amountCents, frequency: r.frequency, anchorDate: r.anchorDate,
                               matchKey: r.matchKey, matchExactAmount: r.matchExactAmount, categoryId: r.categoryId, accountId: r.accountId,
                               active: r.active, notes: r.notes)
    }
}

struct RecurringEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: RecurringDraft
    @State private var amount: Int64?
    @State private var anchor = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.recurringId == nil ? "Add recurring item" : "Edit recurring item").font(Font.app(.title3).weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                Picker("Type", selection: $draft.input.kind) {
                    Text("Bill").tag("bill")
                    Text("Income").tag("income")
                }
                .pickerStyle(.segmented)
                TextField("Name", text: $draft.input.name)
                MoneyField(title: "Amount", cents: $amount)
                Picker("Repeats", selection: $draft.input.frequency) {
                    ForEach(Frequencies.all, id: \.0) { f in Text(f.1).tag(f.0) }
                }
                DatePicker("Happens on (any one date)", selection: $anchor, displayedComponents: .date)
                Picker(draft.input.kind == "income" ? "Deposited to" : "Paid from", selection: $draft.input.accountId) {
                    Text("Not set").tag(String?.none)
                    ForEach(model.accounts) { a in Text(a.name).tag(Optional(a.id)) }
                }
                Text("Bills paid from a credit card show on the calendar but don't lower projected cash.").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                Picker("Category", selection: $draft.input.categoryId) {
                    Text("None").tag(String?.none)
                    ForEach(model.categories) { c in Text(c.name).tag(Optional(c.id)) }
                }
                TextField("Find in transactions by merchant", text: $draft.input.matchKey, prompt: Text("e.g. CITY ELECTRIC"))
                Toggle("Only match this exact amount", isOn: $draft.input.matchExactAmount)
                Toggle("Active", isOn: $draft.input.active)
                TextField("Notes", text: $draft.input.notes, axis: .vertical).lineLimit(2...3)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
                    .disabled(draft.input.name.trimmingCharacters(in: .whitespaces).isEmpty || (amount ?? 0) == 0)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear {
            amount = draft.input.amountCents > 0 ? draft.input.amountCents : nil
            anchor = Dates.date(draft.input.anchorDate) ?? Date()
        }
    }

    private func save() {
        var i = draft.input
        i.amountCents = abs(amount ?? 0)
        i.anchorDate = Dates.string(anchor)
        let id = draft.recurringId
        let input = i
        Task {
            let ok = await model.write { l -> Bool in
                if let id { try l.updateRecurring(id: id, input: input) } else { _ = try l.createRecurring(input: input) }
                return true
            }
            if ok == true { dismiss() }
        }
    }
}

struct FindRecurringSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [RecurringSuggestion]?
    @State private var chosen = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find paychecks and bills").font(Font.app(.title3).weight(.semibold))
            Text("These repeat in your transactions. Likely bills start checked; one-off look-alikes (the same pizza order twice) don't.")
                .foregroundStyle(Ink.secondary)
            if let list = suggestions {
                let visible = list.filter { $0.suggestedKind != "debt" && !$0.alreadyTracked }
                let debts = list.filter { $0.suggestedKind == "debt" && !$0.alreadyTracked }.count
                if visible.isEmpty {
                    Text("Nothing new found.").foregroundStyle(Ink.secondary).frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    List {
                        ForEach(["income", "bill"], id: \.self) { kind in
                            let rows = visible.filter { $0.suggestedKind == kind }
                            if !rows.isEmpty {
                                Section(kind == "income" ? "Income" : "Bills") {
                                    ForEach(rows) { s in row(s) }
                                }
                            }
                        }
                    }
                    .frame(minHeight: 420)
                }
                if debts > 0 {
                    Text("\(debts) repeating debt payment\(debts == 1 ? " was" : "s were") also found. Add those on the Debt page (Find Debts) so payoff dates are tracked.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack {
                Button("Select None") { chosen.removeAll() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count)") { add() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task {
            suggestions = await model.run { try $0.recurringSuggestions() } ?? []
            chosen = Set(suggestions?.filter { $0.recommended && !$0.alreadyTracked && $0.suggestedKind != "debt" }.map(\.id) ?? [])
        }
    }

    private func row(_ s: RecurringSuggestion) -> some View {
        Toggle(isOn: Binding(get: { chosen.contains(s.id) }, set: { on in if on { chosen.insert(s.id) } else { chosen.remove(s.id) } })) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.input.name.squished).lineLimit(1)
                    Text("Seen \(s.occurrences)× · last \(Dates.medium(s.lastDate))" + (s.categoryName.map { " · \($0)" } ?? "") + (s.accountName.map { " · \($0)" } ?? ""))
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                Spacer()
                Text(Money.format(s.input.amountCents) + Frequencies.short(s.input.frequency)).monospacedDigit()
                Text(s.nextDate.map { "next " + Dates.short($0) } ?? "").font(Font.app(.caption)).foregroundStyle(Ink.secondary).frame(width: 80, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func add() {
        let inputs = suggestions?.filter { chosen.contains($0.id) }.map(\.input) ?? []
        Task {
            if let n = await model.write({ l -> Int in
                for i in inputs { _ = try l.createRecurring(input: i) }
                return inputs.count
            }) {
                model.notice = "Added \(n) recurring item\(n == 1 ? "" : "s")."
                dismiss()
            }
        }
    }
}

/// Enter today's real balance for cash accounts so the projection starts from the truth.
struct CashBalancesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: Int64?] = [:]

    private var cashAccounts: [Account] { model.accounts.filter { ["checking", "savings", "cash"].contains($0.kind) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's cash balances").font(Font.app(.title3).weight(.semibold))
            Text("Check your bank and enter the current balance. Imports alone can't know it, because they only start partway through your history.")
                .foregroundStyle(Ink.secondary)
            Form {
                ForEach(cashAccounts) { a in
                    MoneyField(title: a.name + (a.balanceSet ? "" : " (not set)"), cents: Binding(get: { values[a.id] ?? nil }, set: { values[a.id] = $0 }))
                }
            }
            .formStyle(.grouped)
            Text("You can change these later on the Accounts page.").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            for a in cashAccounts { values[a.id] = a.balanceSet ? a.balanceCents : nil }
        }
    }

    private func save() {
        let updates = cashAccounts.compactMap { a -> (String, Int64)? in
            guard let v = values[a.id] ?? nil else { return nil }
            return (a.id, v)
        }
        Task {
            await model.write { l in
                for (id, cents) in updates {
                    try l.updateAccount(id: id, patch: AccountPatch(name: nil, institution: nil, kind: nil, balanceCents: cents, color: nil, archived: nil, dueDay: nil))
                }
            }
            dismiss()
        }
    }
}
