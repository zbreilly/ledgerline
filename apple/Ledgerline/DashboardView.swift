import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var overview: Overview?
    @State private var breakdown: Breakdown?
    @State private var showIncome = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MonthStepper(month: $model.month)
                    Spacer()
                    if let o = overview, o.uncategorized > 0 {
                        Button {
                            model.showTransactions(TxPreset(uncategorizedOnly: true))
                        } label: {
                            Label("\(o.uncategorized) uncategorized", systemImage: "exclamationmark.circle")
                        }
                        .tint(Color.warning)
                    }
                }
                if model.activeAccount == nil, let fo = model.overview {
                    NetWorthPanel(o: fo)
                }
                if let o = overview {
                    kpis(o)
                    HStack(alignment: .top, spacing: 16) {
                        cashflowPanel(o)
                        breakdownPanel
                    }
                    HStack(alignment: .top, spacing: 16) {
                        merchantsPanel(o)
                        recentPanel(o)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .task(id: model.reloadKey + "\(showIncome)") { await load() }
    }

    private func load() async {
        let m = model.month, a = model.activeAccount, inc = showIncome
        if let r = await model.run({ l in (try l.overview(month: m, accountId: a), try l.breakdown(month: m, income: inc, accountId: a)) }) {
            overview = r.0
            breakdown = r.1
        }
    }

    private func kpis(_ o: Overview) -> some View {
        HStack(spacing: 12) {
            StatCard(title: "Money In", value: Money.format(o.incomeCents), detail: change(o.incomeCents, o.prevIncomeCents), tint: Color.positive)
            StatCard(title: "Money Out", value: Money.format(o.expenseCents), detail: change(o.expenseCents, o.prevExpenseCents))
            StatCard(title: "Net Cashflow", value: Money.format(o.netCents, sign: true), detail: "Last month \(Money.format(o.prevNetCents, sign: true))",
                     tint: o.netCents >= 0 ? Color.positive : Color.negative)
            StatCard(title: "Savings Rate", value: o.savingsRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                     detail: "\(o.txCount) transactions")
            StatCard(title: "Cash on Hand", value: Money.format(o.liquidBalanceCents), detail: "Checking, savings, cash")
        }
    }

    private func change(_ cur: Int64, _ prev: Int64) -> String {
        guard prev != 0 else { return "No data last month" }
        let pct = (Double(cur) - Double(prev)) / Double(prev) * 100
        return String(format: "%@%.0f%% vs last month", pct >= 0 ? "+" : "", pct)
    }

    private func cashflowPanel(_ o: Overview) -> some View {
        Panel(title: "Cash flow, last 6 months") {
            Chart {
                ForEach(o.series) { m in
                    BarMark(x: .value("Month", m.label), y: .value("Amount", Double(m.incomeCents) / 100))
                        .foregroundStyle(by: .value("Flow", "Money in"))
                        .position(by: .value("Flow", "Money in"))
                    BarMark(x: .value("Month", m.label), y: .value("Amount", Double(m.expenseCents) / 100))
                        .foregroundStyle(by: .value("Flow", "Money out"))
                        .position(by: .value("Flow", "Money out"))
                }
                ForEach(o.series) { m in
                    LineMark(x: .value("Month", m.label), y: .value("Net", Double(m.netCents) / 100))
                        .foregroundStyle(.purple)
                        .symbol(.circle)
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Money in": Color.positive, "Money out": Color.pink])
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Money.format(Int64(d * 100), compact: true)) } }
                }
            }
            .frame(height: 240)
            Text("Purple line: net (in minus out). Transfers are excluded.").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
        }
    }

    private var breakdownPanel: some View {
        Panel(title: showIncome ? "Income by category" : "Spending by category",
              trailing: AnyView(Picker("", selection: $showIncome) {
                  Text("Spending").tag(false)
                  Text("Income").tag(true)
              }.pickerStyle(.segmented).labelsHidden().frame(width: 170))) {
            if let b = breakdown, !b.categories.isEmpty || b.uncategorizedCents > 0 {
                let total = b.categories.reduce(0) { $0 + $1.totalCents } + b.uncategorizedCents
                HStack(alignment: .top, spacing: 16) {
                    Chart {
                        ForEach(b.categories) { c in
                            SectorMark(angle: .value("Total", Double(c.totalCents)), innerRadius: .ratio(0.6), angularInset: 1)
                                .foregroundStyle(Color(hex: c.color))
                        }
                        if b.uncategorizedCents > 0 {
                            SectorMark(angle: .value("Total", Double(b.uncategorizedCents)), innerRadius: .ratio(0.6), angularInset: 1)
                                .foregroundStyle(Color.gray.opacity(0.4))
                        }
                    }
                    .chartBackground { _ in
                        VStack {
                            Text(Money.format(total, compact: true)).font(Font.app(.headline).monospacedDigit())
                            Text("total").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                        }
                    }
                    .frame(width: 180, height: 180)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(b.categories.prefix(9)) { c in
                            Button {
                                model.showTransactions(TxPreset(categoryId: c.id, month: model.month))
                            } label: {
                                HStack {
                                    Circle().fill(Color(hex: c.color)).frame(width: 8, height: 8)
                                    Text("\(c.icon == "folder" ? "" : c.icon + " ")\(c.name)").lineLimit(1)
                                    Spacer()
                                    Text(Money.format(c.totalCents)).monospacedDigit()
                                    Text(pct(c.totalCents, total)).font(Font.app(.caption)).foregroundStyle(Ink.secondary).frame(width: 36, alignment: .trailing)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if b.uncategorizedCents > 0 {
                            HStack {
                                Circle().fill(.gray.opacity(0.4)).frame(width: 8, height: 8)
                                Text("Uncategorized (\(b.uncategorizedCount))").foregroundStyle(Color.warning)
                                Spacer()
                                Text(Money.format(b.uncategorizedCents)).monospacedDigit()
                                Text(pct(b.uncategorizedCents, total)).font(Font.app(.caption)).foregroundStyle(Ink.secondary).frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                    .font(Font.app(.callout))
                }
            } else {
                Text("Nothing this month.").foregroundStyle(Ink.secondary).frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    private func pct(_ part: Int64, _ total: Int64) -> String {
        total > 0 ? String(format: "%.0f%%", Double(part) / Double(total) * 100) : ""
    }

    private func merchantsPanel(_ o: Overview) -> some View {
        Panel(title: "Top merchants") {
            if o.merchants.isEmpty {
                Text("No spending this month.").foregroundStyle(Ink.secondary)
            }
            let maxV = o.merchants.map(\.totalCents).max() ?? 1
            ForEach(o.merchants) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(m.name.squished).lineLimit(1)
                        Spacer()
                        Text(Money.format(m.totalCents)).monospacedDigit()
                    }
                    GeometryReader { g in
                        Capsule().fill(.pink.opacity(0.5)).frame(width: max(4, g.size.width * CGFloat(m.totalCents) / CGFloat(maxV)), height: 4)
                    }
                    .frame(height: 4)
                }
                .font(Font.app(.callout))
            }
        }
        .frame(maxWidth: 380)
    }

    private func recentPanel(_ o: Overview) -> some View {
        Panel(title: "Recent transactions", trailing: AnyView(Button("See all") { model.showTransactions(TxPreset()) }.buttonStyle(.link))) {
            ForEach(o.recent) { t in
                HStack {
                    Text(Dates.short(t.date)).foregroundStyle(Ink.secondary).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.displayName).lineLimit(1)
                        HStack(spacing: 6) {
                            CategoryBadge(name: t.categoryName, color: t.categoryColor, icon: t.categoryIcon, sub: t.subcategoryName)
                            if t.isTransfer { Text("Transfer").foregroundStyle(Ink.secondary) }
                        }
                        .font(Font.app(.caption))
                    }
                    Spacer()
                    AmountText(cents: t.amountCents)
                }
                .font(Font.app(.callout))
                Divider()
            }
        }
    }
}

/// The whole picture: cash + investments − every debt, and the monthly money plan.
struct NetWorthPanel: View {
    @Environment(AppModel.self) private var model
    let o: FinancialOverview
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Net Worth").font(Font.app(.subheadline)).foregroundStyle(Ink.secondary)
                    Text(Money.format(o.netWorthCents)).font(.system(size: 30, weight: .semibold).monospacedDigit())
                        .foregroundStyle(o.netWorthCents < 0 ? Color.negative : Color.themeText)
                }
                Spacer()
                Text("As of \(Dates.medium(o.asOf)) · Cash + investments − all debts").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                Button(showDetails ? "Hide Details" : "Show Details") { showDetails.toggle() }.buttonStyle(.link)
            }
            HStack(spacing: 12) {
                tile("Cash", o.cashCents, Color.themeText, note: o.cashNeedsSetup ? "Set real balance" : nil) { model.page = .accounts }
                tile("Investments", o.investmentsCents, Color.positive, note: nil) { model.page = .investments }
                tile("Debt", -o.debtCents, Color.negative, note: o.debtsMissingBalance > 0 ? "\(o.debtsMissingBalance) without a balance" : nil) { model.page = .debts }
            }
            Divider()
            HStack(spacing: 18) {
                flow("Monthly income", o.monthlyIncomeCents, Color.positive, help: o.incomeFromSchedule ? "From your scheduled paychecks" : "3-month average of deposits")
                Text("−").foregroundStyle(Ink.secondary)
                flow("Bills", o.monthlyBillsCents, Color.themeText, help: "Recurring bills paid from cash, per month")
                Text("−").foregroundStyle(Ink.secondary)
                flow("Debt payments", o.monthlyDebtPaymentsCents, Color.warning, help: "All debt payments, per month")
                Text("−").foregroundStyle(Ink.secondary)
                flow("Spending budgets", o.monthlyFlexibleCents, .purple, help: "Groceries, dining, fuel, shopping and other budgets not already covered by bills")
                Text("=").foregroundStyle(Ink.secondary)
                flow("Left each month", o.monthlyLeftCents, o.monthlyLeftCents >= 0 ? Color.positive : Color.negative, help: "After bills, debt payments, and your spending budgets")
                Spacer()
                if let dti = o.debtToIncome {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Debt payments / take-home").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                        Text(String(format: "%.0f%%", dti * 100)).font(Font.app(.title3).weight(.semibold).monospacedDigit())
                    }
                }
            }
            if showDetails {
                Divider()
                ForEach(["cash", "investments", "debt"], id: \.self) { g in
                    let rows = o.lines.filter { $0.group == g }
                    if !rows.isEmpty {
                        Text(g == "cash" ? "Cash" : g == "investments" ? "Investments" : "Debt").font(Font.app(.subheadline).weight(.medium)).padding(.top, 4)
                        ForEach(rows) { l in
                            HStack {
                                Text(l.name.squished).lineLimit(1)
                                if l.needsAttention { Image(systemName: "exclamationmark.circle").foregroundStyle(Color.warning) }
                                Text(l.detail).font(Font.app(.caption)).foregroundStyle(Ink.secondary).lineLimit(1)
                                Spacer()
                                Text(Money.format(l.amountCents)).monospacedDigit().foregroundStyle(l.amountCents < 0 ? Color.negative : Color.themeText)
                            }
                            .font(Font.app(.callout))
                        }
                    }
                }
            }
        }
        .padding(16)
        .surface(.panel, radius: 12)
    }

    private func tile(_ title: String, _ cents: Int64, _ tint: Color, note: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Font.app(.subheadline)).foregroundStyle(Ink.secondary)
                Text(Money.format(cents)).font(Font.app(.title2).weight(.semibold).monospacedDigit()).foregroundStyle(tint)
                Text(note ?? " ").font(Font.app(.caption)).foregroundStyle(Color.warning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .surface(.card, radius: 8, primary: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func flow(_ title: String, _ cents: Int64, _ tint: Color, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            Text(Money.format(cents)).font(Font.app(.title3).weight(.semibold).monospacedDigit()).foregroundStyle(tint)
        }
        .help(help)
    }
}
