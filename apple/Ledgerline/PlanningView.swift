import Charts
import SwiftUI

struct PlanningView: View {
    @Environment(AppModel.self) private var model
    @State private var plan: Planning?
    @State private var budgetTarget: BudgetTarget?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MonthStepper(month: $model.month)
                    Spacer()
                    Text("Budgets are monthly. A category budget overrides the sum of its subcategory budgets.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
                if let p = plan {
                    metrics(p)
                    budgetChart(p)
                    budgetTable(p)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .task(id: model.reloadKey) { await load() }
        .sheet(item: $budgetTarget) { t in BudgetEditor(target: t).themedControls() }
    }

    private func load() async {
        let m = model.month, a = model.activeAccount
        plan = await model.run { try $0.planning(month: m, accountId: a) }
    }

    private func metrics(_ p: Planning) -> some View {
        let m = p.metrics
        let left = p.budgetedCents - p.actualCents
        return HStack(spacing: 12) {
            StatCard(title: "Budgeted", value: Money.format(p.budgetedCents),
                     detail: p.budgetedCents > 0 ? "\(Money.format(abs(left))) \(left >= 0 ? "left" : "over")" : "No budgets yet",
                     tint: left >= 0 ? Color.themeText : Color.negative)
            StatCard(title: "Spent", value: Money.format(p.actualCents),
                     detail: m.projectedExpenseCents.map { "On pace for \(Money.format($0))" } ?? "Month complete")
            StatCard(title: "Savings Rate", value: m.savingsRateMonth.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                     detail: m.savingsRate3m.map { String(format: "3-month: %.0f%%", $0 * 100) })
            StatCard(title: "Avg Monthly Spend", value: Money.format(m.avgExpense3mCents), detail: "Income \(Money.format(m.avgIncome3mCents)) / mo")
            StatCard(title: "Runway", value: m.runwayMonths.map { String(format: "%.1f mo", $0) } ?? "—",
                     detail: "Cash \(Money.format(m.liquidBalanceCents))")
        }
    }

    private func budgetChart(_ p: Planning) -> some View {
        let rows = p.tree.filter { $0.budgetCents > 0 || $0.actualCents > 0 }.prefix(14)
        return Panel(title: "Budget vs actual") {
            if rows.isEmpty {
                Text("No spending or budgets this month.").foregroundStyle(Ink.secondary)
            } else {
                let maxV = CGFloat(rows.map { max(effectiveBudget($0), $0.actualCents) }.max() ?? 1)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows)) { c in
                        let budget = effectiveBudget(c)
                        HStack(spacing: 12) {
                            Text(c.name).font(Font.app(.callout)).frame(width: 170, alignment: .trailing).lineLimit(1)
                            GeometryReader { g in
                                VStack(alignment: .leading, spacing: 2) {
                                    Capsule().fill(Color.gray.opacity(0.4))
                                        .frame(width: max(budget > 0 ? 3 : 0, g.size.width * CGFloat(budget) / maxV), height: 7)
                                    Capsule().fill(budget > 0 && c.actualCents > budget ? Color.negative : Color.themeAccent)
                                        .frame(width: max(3, g.size.width * CGFloat(c.actualCents) / maxV), height: 7)
                                }
                            }
                            .frame(height: 16)
                            Text("\(Money.format(c.actualCents, compact: true)) / \(budget > 0 ? Money.format(budget, compact: true) : "—")")
                                .font(Font.app(.caption).monospacedDigit()).foregroundStyle(Ink.secondary).frame(width: 110, alignment: .trailing)
                        }
                    }
                    HStack(spacing: 14) {
                        Label("Budget", systemImage: "circle.fill").foregroundStyle(.gray)
                        Label("Spent", systemImage: "circle.fill").foregroundStyle(Color.themeAccent)
                        Label("Over budget", systemImage: "circle.fill").foregroundStyle(Color.negative)
                    }
                    .font(Font.app(.caption))
                    .padding(.leading, 182)
                }
            }
        }
    }

    private func effectiveBudget(_ c: PlanCategory) -> Int64 {
        c.budgetCents > 0 ? c.budgetCents : c.subcategories.reduce(0) { $0 + $1.budgetCents }
    }

    private func budgetTable(_ p: Planning) -> some View {
        Panel(title: "Categories", trailing: AnyView(Menu("Add Budget") {
            ForEach(model.categories.filter { $0.kind == "expense" }) { c in
                Button(c.name) { budgetTarget = target(p, categoryId: c.id, categoryName: c.name, sub: nil) }
            }
        }.fixedSize())) {
            ForEach(p.tree) { c in
                VStack(alignment: .leading, spacing: 6) {
                    BudgetRow(name: "\(c.icon == "folder" ? "" : c.icon + " ")\(c.name)", color: Color(hex: c.color), actual: c.actualCents,
                              budget: effectiveBudget(c), inherited: c.budgetCents == 0 && effectiveBudget(c) > 0, bold: true) {
                        budgetTarget = target(p, categoryId: c.id, categoryName: c.name, sub: nil)
                    }
                    ForEach(c.subcategories) { s in
                        BudgetRow(name: s.name, color: Color(hex: c.color).opacity(0.5), actual: s.actualCents, budget: s.budgetCents,
                                  inherited: false, bold: false) {
                            budgetTarget = target(p, categoryId: c.id, categoryName: c.name, sub: s)
                        }
                        .padding(.leading, 22)
                    }
                }
                Divider()
            }
        }
    }
}

struct BudgetRow: View {
    let name: String
    let color: Color
    let actual: Int64
    let budget: Int64
    let inherited: Bool
    let bold: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(bold ? Font.app(.body).weight(.medium) : Font.app(.callout)).frame(width: 220, alignment: .leading).lineLimit(1)
            ProgressView(value: budget > 0 ? min(Double(actual) / Double(budget), 1) : 0)
                .tint(budget > 0 && actual > budget ? Color.negative : color)
                .opacity(budget > 0 ? 1 : 0.25)
            Text(Money.format(actual)).monospacedDigit().frame(width: 100, alignment: .trailing)
            Group {
                if budget > 0 {
                    Text("of \(Money.format(budget))\(inherited ? "*" : "")").help(inherited ? "Sum of subcategory budgets" : "")
                } else {
                    Text("no budget")
                }
            }
            .foregroundStyle(Ink.secondary).monospacedDigit().frame(width: 120, alignment: .leading)
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Set budget")
        }
    }
}

extension PlanningView {
    /// Everything the editor needs to show what's left as you type.
    func target(_ p: Planning, categoryId: String, categoryName: String, sub: PlanSub?) -> BudgetTarget {
        let c = p.tree.first { $0.id == categoryId }
        let subs = c?.subcategories ?? []
        let subTotal = subs.reduce(Int64(0)) { $0 + $1.budgetCents }
        let catBudget = c?.budgetCents ?? 0
        let effective = catBudget > 0 ? catBudget : subTotal
        return BudgetTarget(
            categoryId: categoryId,
            subcategoryId: sub?.id,
            name: sub.map { "\(categoryName) › \($0.name)" } ?? categoryName,
            categoryName: categoryName,
            cents: sub?.budgetCents ?? catBudget,
            categoryBudgetCents: catBudget,
            otherSubBudgetsCents: subTotal - (sub?.budgetCents ?? 0),
            subBudgetsTotalCents: subTotal,
            spentThisMonthCents: sub?.actualCents ?? c?.actualCents ?? 0,
            totalBudgetedCents: p.budgetedCents,
            currentEffectiveCents: effective,
            month: p.month)
    }
}

struct BudgetTarget: Identifiable {
    var id: String { categoryId + (subcategoryId ?? "") }
    let categoryId: String
    let subcategoryId: String?
    let name: String
    let categoryName: String
    let cents: Int64
    /// Category-level budget (0 = the category is the sum of its subcategory budgets).
    let categoryBudgetCents: Int64
    /// Other subcategories' budgets in the same category (excluding this one).
    let otherSubBudgetsCents: Int64
    let subBudgetsTotalCents: Int64
    let spentThisMonthCents: Int64
    /// All budgets combined, before this change.
    let totalBudgetedCents: Int64
    /// What this category currently counts for in that total.
    let currentEffectiveCents: Int64
    let month: String
}

struct BudgetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: BudgetTarget
    @State private var cents: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly budget for \(target.name)").font(Font.app(.headline))
            MoneyField(title: "Amount", cents: $cents)
            Text("Set to 0 to remove the budget.").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            liveBreakdown
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = target, amount = abs(cents ?? 0)
                    Task {
                        let ok = await model.write { l -> Bool in
                            _ = try l.setBudget(categoryId: t.categoryId, subcategoryId: t.subcategoryId, amountCents: amount)
                            return true
                        }
                        if ok == true { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
                .disabled(overCategory)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { cents = target.cents }
    }

    private var typed: Int64 { abs(cents ?? 0) }
    private var isSub: Bool { target.subcategoryId != nil }

    /// A subcategory can't take more than its category's budget leaves.
    private var categoryRemaining: Int64? {
        guard isSub, target.categoryBudgetCents > 0 else { return nil }
        return target.categoryBudgetCents - target.otherSubBudgetsCents - typed
    }

    private var overCategory: Bool { (categoryRemaining ?? 0) < 0 }

    /// The category's share of the overall total after this change.
    private var newEffective: Int64 {
        if isSub {
            return target.categoryBudgetCents > 0 ? target.categoryBudgetCents : target.otherSubBudgetsCents + typed
        }
        return typed > 0 ? typed : target.subBudgetsTotalCents
    }

    private var newTotal: Int64 { target.totalBudgetedCents - target.currentEffectiveCents + newEffective }

    /// Updates on every keystroke.
    private var liveBreakdown: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            if isSub {
                if target.categoryBudgetCents > 0 {
                    row("\(target.categoryName) budget", Money.format(target.categoryBudgetCents))
                    row("Other subcategories", "− " + Money.format(target.otherSubBudgetsCents))
                    row("This subcategory", "− " + Money.format(typed))
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("Left in \(target.categoryName)", Money.format(categoryRemaining ?? 0),
                        tint: overCategory ? Color.negative : Color.positive, bold: true)
                    if overCategory {
                        Text("That's more than \(target.categoryName) has left. Lower it, or raise the \(target.categoryName) budget first.")
                            .font(Font.app(.caption)).foregroundStyle(Color.negative).gridCellColumns(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    row("Other subcategories", Money.format(target.otherSubBudgetsCents))
                    row("\(target.categoryName) total becomes", Money.format(target.otherSubBudgetsCents + typed), bold: true)
                }
            } else if target.subBudgetsTotalCents > 0 {
                row("Subcategory budgets", Money.format(target.subBudgetsTotalCents))
                if typed > 0 {
                    let left = typed - target.subBudgetsTotalCents
                    row("Left for the rest of \(target.categoryName)", Money.format(left), tint: left < 0 ? Color.negative : Color.positive, bold: true)
                    if left < 0 {
                        Text("Your subcategory budgets already add up to more than this.")
                            .font(Font.app(.caption)).foregroundStyle(Color.negative).gridCellColumns(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            let spentLeft = typed - target.spentThisMonthCents
            row("Spent in \(Dates.monthTitle(target.month))", Money.format(target.spentThisMonthCents))
            if typed > 0 {
                row(spentLeft >= 0 ? "Left to spend this month" : "Over budget this month", Money.format(abs(spentLeft)),
                    tint: spentLeft >= 0 ? Color.positive : Color.negative)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("All budgets", Money.format(newTotal) + delta)
            if let income = model.overview?.monthlyIncomeCents, income > 0 {
                let unbudgeted = income - newTotal
                row(unbudgeted >= 0 ? "Take-home not budgeted" : "Budgeted beyond take-home", Money.format(abs(unbudgeted)),
                    tint: unbudgeted >= 0 ? Color.themeSecondary : Color.negative)
            }
        }
        .font(Font.app(.callout))
        .padding(12)
        .surface(.card, radius: 8)
    }

    private var delta: String {
        let d = newTotal - target.totalBudgetedCents
        return d == 0 ? "" : " (\(Money.format(d, sign: true)))"
    }

    private func row(_ label: String, _ value: String, tint: Color = Color.themeText, bold: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(Ink.secondary)
            Text(value).monospacedDigit().fontWeight(bold ? .semibold : .regular).foregroundStyle(tint)
                .gridColumnAlignment(.trailing)
        }
    }
}
