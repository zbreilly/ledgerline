import SwiftUI

struct TransactionsView: View {
    @Environment(AppModel.self) private var model

    @State private var page: TxPage?
    @State private var search = ""
    @State private var categoryFilter: String? = nil   // "none" = uncategorized
    @State private var subcategoryFilter: String? = nil
    @State private var flow: String? = nil
    @State private var transfers = "exclude"
    @State private var allMonths = false
    @State private var pageNumber: UInt32 = 1
    @State private var sortOrder = [KeyPathComparator(\Transaction.date, order: .reverse)]
    @State private var selection = Set<String>()

    @State private var editing: Transaction?
    @State private var splitting: Transaction?
    @State private var showAISort = false
    @State private var showRules = false
    /// True while the search field has the cursor (Edit › Find Transactions puts it there).
    @State private var searching = false
    @State private var notesFor: Set<String>?
    @State private var notesText = ""
    @State private var confirmDelete: Set<String>?

    private let pageSize: UInt32 = 200

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
            Divider()
            footer
        }
        .searchable(text: $search, isPresented: $searching, placement: .toolbar, prompt: "Search description, merchant, notes")
        .toolbar {
            ToolbarItemGroup {
                Button { showRules = true } label: { Label("Rules", systemImage: "list.bullet.indent") }.buttonStyle(.automatic)
                    .help("Auto-categorization rules")
                Button { Task { await model.applyMemory() } } label: { Label("Memory", systemImage: "brain") }.buttonStyle(.automatic)
                    .help("Fill uncategorized rows from merchants you've categorized before")
                Button { showAISort = true } label: { Label("AI Sort", systemImage: "sparkles") }.buttonStyle(.automatic)
                    .help("Suggest categories for uncategorized transactions")
            }
        }
        .task(id: queryKey) { await load() }
        .onAppear(perform: consumePreset)
        .onChange(of: model.txPreset) { _, _ in consumePreset() }
        .onChange(of: search) { _, _ in pageNumber = 1 }
        .onCommand(.showRules, .aiSort, .searchTransactions) { command in
            switch command {
            case .showRules: showRules = true
            case .aiSort: showAISort = true
            default: searching = true
            }
        }
        .sheet(item: $editing) { t in
            TransactionEditor(tx: t, onSplit: {
                // Let the editor close before the split sheet opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { splitting = t }
            })
            .themedControls()
        }
        .sheet(item: $splitting) { t in SplitSheet(tx: t).themedControls() }
        .sheet(isPresented: $showAISort) { AISortSheet(selectedIds: Array(selection)).themedControls() }
        .sheet(isPresented: $showRules) { RulesSheet().themedControls() }
        .sheet(item: Binding(get: { notesFor.map(IDSet.init) }, set: { notesFor = $0?.ids })) { set in
            VStack(alignment: .leading, spacing: 12) {
                Text("Set notes on \(set.ids.count) transaction\(set.ids.count == 1 ? "" : "s")").font(Font.app(.headline))
                TextField("Notes", text: $notesText, axis: .vertical).lineLimit(3...6)
                HStack {
                    Spacer()
                    Button("Cancel") { notesFor = nil }
                    Button("Save") {
                        let ids = Array(set.ids), n = notesText
                        notesFor = nil
                        Task { await model.write { try $0.bulkSetNotes(ids: ids, notes: n) } }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
                }
            }
            .padding(20)
            .frame(width: 420)
            .themedControls()
        }
        .confirmationDialog("Delete \(confirmDelete?.count ?? 0) transaction(s)?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                let ids = Array(confirmDelete ?? [])
                confirmDelete = nil
                selection.removeAll()
                Task { await model.write { try $0.deleteTransactions(ids: ids) } }
            }
        } message: {
            Text("This can't be undone. Re-importing the CSV would bring them back.")
        }
    }

    // MARK: - Query

    private var sortKey: (String, Bool) {
        guard let c = sortOrder.first else { return ("date", false) }
        let asc = c.order == .forward
        switch c.keyPath {
        case \Transaction.amountCents: return ("amount", asc)
        case \Transaction.description: return ("description", asc)
        case \Transaction.accountSort: return ("account", asc)
        case \Transaction.categorySort: return ("category", asc)
        case \Transaction.subcategorySort: return ("subcategory", asc)
        default: return ("date", asc)
        }
    }

    private var query: TxQuery {
        let (sort, asc) = sortKey

        return TxQuery(
            search: search.isEmpty ? nil : search,
            accountIds: model.activeAccount.map { [$0] } ?? [],
            categoryIds: categoryFilter.map { [$0] } ?? [],
            subcategoryIds: subcategoryFilter.map { [$0] } ?? [],
            dateFrom: nil, dateTo: nil, month: allMonths ? nil : model.month,
            minCents: nil, maxCents: nil,
            flow: flow,
            uncategorizedOnly: false,
            transfers: transfers,
            sort: sort, ascending: asc,
            page: pageNumber, pageSize: pageSize)
    }

    private var queryKey: String {
        let q = query
        return "\(model.revision)|\(q.search ?? "")|\(q.accountIds)|\(q.categoryIds)|\(q.subcategoryIds)|\(q.month ?? "all")|\(q.flow ?? "")|\(q.transfers)|\(q.sort)|\(q.ascending)|\(q.page)"
    }

    private func load() async {
        let q = query
        if let p = await model.run({ try $0.listTransactions(query: q) }) {
            page = p
            selection = selection.intersection(Set(p.rows.map(\.id)))
        }
    }

    private func showMostRecent() {
        Task {
            if let m = await model.run({ try $0.latestTransactionMonth() }), let m {
                allMonths = false
                model.month = m
            }
        }
    }

    private func consumePreset() {
        guard let p = model.txPreset else { return }
        model.txPreset = nil
        search = ""
        flow = nil
        transfers = "exclude"
        pageNumber = 1
        categoryFilter = p.uncategorizedOnly ? "none" : p.categoryId
        subcategoryFilter = nil
        allMonths = p.month == nil
        if let m = p.month { model.month = m }
    }

    // MARK: - Views

    /// Subcategories of the category picked in the filter.
    private var subcategoryChoices: [Subcategory] {
        model.categories.first { $0.id == categoryFilter }?.subcategories ?? []
    }

    private static let sortOptions: [(String, String, PartialKeyPath<Transaction>)] = [
        ("date", "Date", \Transaction.date), ("amount", "Amount", \Transaction.amountCents),
        ("description", "Description", \Transaction.description), ("category", "Category", \Transaction.categorySort),
        ("subcategory", "Subcategory", \Transaction.subcategorySort), ("account", "Account", \Transaction.accountSort),
    ]

    /// Same sorting as clicking a column header, as a visible button.
    private var sortMenu: some View {
        let (current, asc) = sortKey
        let label = Self.sortOptions.first { $0.0 == current }?.1 ?? "Date"
        return Menu {
            ForEach(Self.sortOptions, id: \.0) { opt in
                Button {
                    // Picking the current sort again flips its direction.
                    let ascending = opt.0 == current ? !asc : (opt.0 != "date" && opt.0 != "amount")
                    setSort(opt.0, ascending: ascending)
                } label: {
                    if opt.0 == current {
                        Label(opt.1, systemImage: asc ? "arrow.up" : "arrow.down")
                    } else {
                        Text(opt.1)
                    }
                }
            }
        } label: {
            Label("Sort: \(label)", systemImage: asc ? "arrow.up" : "arrow.down")
        }
        .fixedSize()
        .help("Sort transactions (you can also click a column header)")
    }

    private func setSort(_ key: String, ascending: Bool) {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "amount": sortOrder = [KeyPathComparator(\Transaction.amountCents, order: order)]
        case "description": sortOrder = [KeyPathComparator(\Transaction.description, order: order)]
        case "category": sortOrder = [KeyPathComparator(\Transaction.categorySort, order: order)]
        case "subcategory": sortOrder = [KeyPathComparator(\Transaction.subcategorySort, order: order)]
        case "account": sortOrder = [KeyPathComparator(\Transaction.accountSort, order: order)]
        default: sortOrder = [KeyPathComparator(\Transaction.date, order: order)]
        }
    }

    private var filterBar: some View {
        // One row when the window is wide enough; otherwise the filters sit above the sorting and month controls.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterPickers
                monthControls
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) { filterPickers }
                HStack(spacing: 12) { monthControls }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onChange(of: categoryFilter) { _, _ in
            pageNumber = 1
            subcategoryFilter = nil
        }
        .onChange(of: subcategoryFilter) { _, _ in pageNumber = 1 }
        .onChange(of: flow) { _, _ in pageNumber = 1 }
        .onChange(of: transfers) { _, _ in pageNumber = 1 }
        .onChange(of: allMonths) { _, _ in pageNumber = 1 }
        .onChange(of: model.month) { _, _ in pageNumber = 1 }
    }

    /// The four filters. Each can narrow a little so a small window still shows all of them.
    private var filterPickers: some View {
        Group {
            Picker("Category", selection: $categoryFilter) {
                Text("All categories").tag(String?.none)
                Text("Uncategorized").tag(Optional("none"))
                Divider()
                ForEach(model.categories) { c in Text(c.name).tag(Optional(c.id)) }
            }
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 180, alignment: .leading)
            Picker("Subcategory", selection: $subcategoryFilter) {
                Text(subcategoryChoices.isEmpty ? "No subcategories" : "All subcategories").tag(String?.none)
                if !subcategoryChoices.isEmpty { Divider() }
                ForEach(subcategoryChoices) { s in Text(s.name).tag(Optional(s.id)) }
            }
            .frame(minWidth: 120, idealWidth: 170, maxWidth: 170, alignment: .leading)
            .disabled(subcategoryChoices.isEmpty)
            .help(categoryFilter == nil || categoryFilter == "none" ? "Pick a category first to filter by its subcategories" : "Filter by subcategory")
            Picker("Type", selection: $flow) {
                Text("In and out").tag(String?.none)
                Text("Money out").tag(Optional("expense"))
                Text("Money in").tag(Optional("income"))
            }
            .frame(minWidth: 100, idealWidth: 130, maxWidth: 130, alignment: .leading)
            Picker("Transfers", selection: $transfers) {
                Text("Hide savings moves").tag("exclude")
                Text("Hide all transfers").tag("hide_all")
                Text("Only transfers").tag("only")
                Text("Show all").tag("all")
            }
            .frame(minWidth: 130, idealWidth: 190, maxWidth: 190, alignment: .leading)
        }
        .labelsHidden()
    }

    /// Sorting, the month, and the account the page is scoped to. The account name is the part that gives way.
    @ViewBuilder private var monthControls: some View {
        sortMenu
        Divider().frame(height: 18)
        if !allMonths {
            MonthStepper(month: Bindable(model).month).fixedSize()
            Button("Show Most Recent", action: showMostRecent)
                .fixedSize()
                .help("Jump to the month of your newest transaction")
        }
        Toggle("All months", isOn: $allMonths).fixedSize()
        Spacer(minLength: 0)
        if let a = model.activeAccount, let acc = model.accounts.first(where: { $0.id == a }) {
            Label(acc.name, systemImage: "creditcard").foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .help("Scoped to this account (change it in the sidebar)")
        }
    }

    private var table: some View {
        Table(page?.rows ?? [], selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.date) { t in
                Text(Dates.medium(t.date)).monospacedDigit()
            }
            .width(min: 90, ideal: 100, max: 120)
            TableColumn("Description", value: \.description) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.displayName).lineLimit(1)
                    if !t.notes.isEmpty { Text(t.notes).font(Font.app(.caption)).foregroundStyle(Ink.secondary).lineLimit(1) }
                    if t.splitOf != nil {
                        Label("Split", systemImage: "square.split.2x1").font(Font.app(.caption)).foregroundStyle(.purple)
                            .help("Part of a split transaction. Right-click to change or undo the split.")
                    }
                    if let rm = t.reportMonth {
                        Label("Counts in \(Dates.monthTitle(rm))", systemImage: "arrow.uturn.backward.circle").font(Font.app(.caption)).foregroundStyle(Color.info)
                    }
                }
                .help(t.description)
            }
            .width(min: 200, ideal: 340)
            TableColumn("Category", value: \.categorySort) { t in
                HStack(spacing: 6) {
                    CategoryBadge(name: t.categoryName, color: t.categoryColor, icon: t.categoryIcon)
                    if t.isTransfer {
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(Ink.secondary).help("Transfer (excluded from reports)")
                    }
                }
            }
            .width(min: 120, ideal: 170)
            TableColumn("Subcategory", value: \.subcategorySort) { t in
                Text(t.subcategoryName ?? "—").foregroundStyle(t.subcategoryName == nil ? Ink.tertiary : Ink.primary).lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Account", value: \.accountSort) { t in
                Text(t.accountName ?? "").foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 140)
            TableColumn("Amount", value: \.amountCents) { t in
                AmountText(cents: t.amountCents).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)
        }
        .onChange(of: sortOrder) { _, _ in pageNumber = 1 }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if ids.count == 1, let t = page?.rows.first(where: { ids.contains($0.id) }) { editing = t }
        }
    }

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        if ids.count == 1, let t = page?.rows.first(where: { ids.contains($0.id) }) {
            Button("Edit…") { editing = t }
            Button(t.splitOf == nil ? "Split…" : "Change Split…") { splitting = t }
            if t.splitOf != nil {
                Button("Undo Split") {
                    let id = t.id
                    Task { await model.write { try $0.unsplitTransaction(id: id) } }
                }
            }
            Divider()
        }
        Menu("Categorize") {
            Button("Uncategorized") { categorize(ids, nil, nil) }
            Divider()
            ForEach(model.categories) { c in
                if c.subcategories.isEmpty {
                    Button(c.name) { categorize(ids, c.id, nil) }
                } else {
                    Menu(c.name) {
                        Button("\(c.name) (no subcategory)") { categorize(ids, c.id, nil) }
                        Divider()
                        ForEach(c.subcategories) { s in Button(s.name) { categorize(ids, c.id, s.id) } }
                    }
                }
            }
        }
        Button("Mark as Transfer") { setTransfer(ids, true) }
        Button("Not a Transfer") { setTransfer(ids, false) }
        Button("Set Notes…") { notesText = ""; notesFor = ids }
        Button("AI Sort Selected…") { selection = ids; showAISort = true }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = ids }
    }

    private func categorize(_ ids: Set<String>, _ cat: String?, _ sub: String?) {
        let arr = Array(ids)
        Task { await model.write { try $0.bulkCategorize(ids: arr, categoryId: cat, subcategoryId: sub) } }
    }

    private func setTransfer(_ ids: Set<String>, _ on: Bool) {
        let arr = Array(ids)
        Task { await model.write { try $0.bulkSetTransfer(ids: arr, isTransfer: on) } }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let p = page {
                Text("\(p.total) transactions").foregroundStyle(Ink.secondary)
                Text("In \(Money.format(p.inflowCents))").foregroundStyle(Color.positive)
                Text("Out \(Money.format(-p.outflowCents))")
                Text("Net \(Money.format(p.inflowCents - p.outflowCents, sign: true))").foregroundStyle(Ink.secondary)
                if p.hiddenTransfers > 0 {
                    HStack(spacing: 4) {
                        Text("· \(p.hiddenTransfers) \(transfers == "hide_all" ? "transfers" : "checking ↔ savings moves") hidden")
                            .foregroundStyle(Ink.secondary)
                        Button("Show") { transfers = "all" }.buttonStyle(.link)
                    }
                }
                if !selection.isEmpty {
                    let sel = p.rows.filter { selection.contains($0.id) }
                    Text("· \(sel.count) selected, \(Money.format(sel.reduce(0) { $0 + $1.amountCents }, sign: true))")
                        .foregroundStyle(Ink.secondary)
                }
                Spacer()
                Button { pageNumber -= 1 } label: { Image(systemName: "chevron.left") }.disabled(p.page <= 1)
                Text("Page \(p.page) of \(p.pages)").monospacedDigit()
                Button { pageNumber += 1 } label: { Image(systemName: "chevron.right") }.disabled(p.page >= p.pages)
            } else {
                Spacer()
            }
        }
        .font(Font.app(.callout).monospacedDigit())
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct IDSet: Identifiable {
    let ids: Set<String>
    var id: String { ids.sorted().joined(separator: ",") }
}

// MARK: - Edit one transaction

struct TransactionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tx: Transaction
    /// Opens the split sheet for this transaction.
    var onSplit: (() -> Void)? = nil

    @State private var date = Date()
    @State private var description = ""
    @State private var merchant = ""
    @State private var amount: Int64? = 0
    @State private var notes = ""
    @State private var isTransfer = false
    @State private var categoryId: String?
    @State private var subcategoryId: String?
    @State private var makeRule = false
    @State private var reportMonth: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit transaction").font(Font.app(.title3).weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Description", text: $description)
                TextField("Merchant", text: $merchant, prompt: Text("Optional cleaner name"))
                MoneyField(title: "Amount", cents: $amount)
                Text("Negative = money out.").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                CategoryPicker(categoryId: $categoryId, subcategoryId: $subcategoryId)
                Toggle("Account transfer (exclude from cash flow)", isOn: $isTransfer)
                Picker("Counts toward", selection: $reportMonth) {
                    Text("Its own month (\(Dates.monthTitle(ownMonth)))").tag(String?.none)
                    ForEach([shiftMonth(month: ownMonth, n: -1), shiftMonth(month: ownMonth, n: 1)], id: \.self) { m in
                        Text(Dates.monthTitle(m)).tag(Optional(m))
                    }
                    if let r = tx.reportMonth, r != shiftMonth(month: ownMonth, n: -1), r != shiftMonth(month: ownMonth, n: 1) {
                        Text(Dates.monthTitle(r)).tag(Optional(r))
                    }
                }
                .help("For example, count a paycheck that lands on the 1st toward the month before")
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4)
                if categoryId != nil && categoryId != tx.categoryId {
                    Toggle("Also create a rule for \"\(ruleKeyword)\"", isOn: $makeRule)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(tx.accountName ?? "").foregroundStyle(Ink.secondary)
                if let onSplit {
                    Button {
                        dismiss()
                        onSplit()
                    } label: { Label(tx.splitOf == nil ? "Split…" : "Change Split…", systemImage: "square.split.2x1") }
                    .help("Split this charge across categories, e.g. groceries and pharmacy")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(amount == nil || description.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear {
            date = Dates.date(tx.date) ?? Date()
            description = tx.description
            merchant = tx.merchant
            amount = tx.amountCents
            notes = tx.notes
            isTransfer = tx.isTransfer
            categoryId = tx.categoryId
            subcategoryId = tx.subcategoryId
            reportMonth = tx.reportMonth
        }
    }

    /// The month of the date currently in the editor.
    private var ownMonth: String { String(Dates.string(date).prefix(7)) }

    /// First meaningful word(s) of the description, used as a "contains" rule pattern.
    private var ruleKeyword: String {
        let words = description.uppercased().split(whereSeparator: { $0 == " " || $0 == "*" })
            .filter { w in !w.contains(where: \.isNumber) && w.count >= 3 && !["POS", "DEBIT", "PURCHASE", "CARD", "TST", "SQ"].contains(String(w)) }
        return words.prefix(2).joined(separator: " ")
    }

    private func save() {
        let patch = TxPatch(date: Dates.string(date), description: description, merchant: merchant, amountCents: amount,
                            notes: notes, isTransfer: isTransfer, setCategory: true, categoryId: categoryId, subcategoryId: subcategoryId, setReportMonth: true, reportMonth: reportMonth)
        let id = tx.id
        let rule: RuleInput? = (makeRule && !ruleKeyword.isEmpty) ? RuleInput(priority: 100, enabled: true, matchType: "contains", field: "description",
            pattern: ruleKeyword, categoryId: categoryId, subcategoryId: subcategoryId, minCents: nil, maxCents: nil) : nil
        dismiss()
        Task {
            await model.write { l in
                try l.updateTransaction(id: id, patch: patch)
                if let rule { _ = try l.createRule(input: rule) }
            }
        }
    }
}

// MARK: - AI Sort

struct AISortSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selectedIds: [String]

    @State private var allowNew = false
    @State private var limit = 100
    @State private var running = false
    @State private var result: SuggestResult?
    @State private var accepted = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Sort").font(Font.app(.title3).weight(.semibold))
            Text(selectedIds.isEmpty
                 ? "Suggests categories for uncategorized transactions only. Nothing changes until you apply."
                 : "Suggests categories for the \(selectedIds.count) selected transaction(s). Nothing changes until you apply.")
                .foregroundStyle(Ink.secondary)
            HStack(spacing: 16) {
                Toggle("Let AI create new categories when needed", isOn: $allowNew)
                if selectedIds.isEmpty {
                    Stepper("Up to \(limit) rows", value: $limit, in: 25...400, step: 25)
                }
                Spacer()
                Text("Provider: \(model.settings?.aiProvider ?? "claude")").foregroundStyle(Ink.secondary)
            }
            if running {
                HStack { ProgressView().controlSize(.small); Text("Asking the AI. This can take a minute or two…") }
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if let r = result {
                if r.suggestions.isEmpty {
                    Text("No suggestions. There may be nothing uncategorized, or the AI couldn't match any category.")
                        .foregroundStyle(Ink.secondary).frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    Table(r.suggestions, selection: $accepted) {
                        TableColumn("Transaction") { s in
                            VStack(alignment: .leading) {
                                Text(s.description).lineLimit(1)
                                Text(Dates.medium(s.date)).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                            }
                        }
                        TableColumn("Amount") { s in AmountText(cents: s.amountCents) }.width(90)
                        TableColumn("Suggested") { s in
                            HStack(spacing: 4) {
                                Text((s.categoryName ?? "?") + (s.subcategoryName.map { " › \($0)" } ?? ""))
                                if s.newCategory { Text("NEW").font(Font.app(.caption2).bold()).foregroundStyle(Color.warning) }
                            }
                            .help(s.reason)
                        }
                        TableColumn("Confidence") { s in
                            Text(String(format: "%.0f%%", s.confidence * 100)).monospacedDigit()
                                .foregroundStyle(s.confidence >= 0.8 ? Color.positive : s.confidence >= 0.5 ? Color.themeText : Color.warning)
                        }
                        .width(80)
                    }
                    .frame(minHeight: 320)
                    Text("Selected rows are applied. Low-confidence rows start unselected. Took \(r.elapsedMs / 1000)s.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            } else {
                Spacer().frame(height: 120)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil || result?.suggestions.isEmpty == true {
                    Button("Get Suggestions") { suggest() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(running)
                } else {
                    Button("Apply \(accepted.count)") { apply() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(accepted.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 820)
    }

    private func suggest() {
        running = true
        let ids = selectedIds, lim = UInt32(limit), allow = allowNew
        Task {
            let r = await model.run { try $0.aiSuggest(ids: ids, limit: lim, offset: 0, allowNew: allow) }
            running = false
            result = r
            accepted = Set(r?.suggestions.filter { $0.confidence >= 0.5 }.map(\.id) ?? [])
        }
    }

    private func apply() {
        let chosen = result?.suggestions.filter { accepted.contains($0.id) } ?? []
        Task {
            if let r = await model.write({ try $0.aiApply(suggestions: chosen) }) {
                var msg = "Categorized \(r.updated) transaction\(r.updated == 1 ? "" : "s")."
                if r.categoriesCreated > 0 { msg += " Created \(r.categoriesCreated) new categor\(r.categoriesCreated == 1 ? "y" : "ies")." }
                model.notice = msg
                dismiss()
            }
        }
    }
}

// MARK: - Rules

struct RulesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [Rule] = []
    @State private var editing: RuleDraft?
    @State private var learned: LearnRulesResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Auto-categorization rules").font(Font.app(.title3).weight(.semibold))
                Spacer()
                Button { learn() } label: { Label("Learn from My Categories", systemImage: "wand.and.stars") }
                    .help("Creates a rule for each merchant you've categorized the same way every time")
                Button { editing = RuleDraft() } label: { Label("New Rule", systemImage: "plus") }
            }
            Text("Rules run on import, in priority order (lowest first). The first match wins. A rule that targets Transfers also marks the row as a transfer.")
                .font(Font.app(.callout)).foregroundStyle(Ink.secondary)
            Table(rules) {
                TableColumn("On") { r in
                    Toggle("", isOn: Binding(get: { r.enabled }, set: { on in toggle(r, on) })).labelsHidden()
                }
                .width(30)
                TableColumn("Priority") { r in Text("\(r.priority)").monospacedDigit() }.width(55)
                TableColumn("When") { r in
                    Text(r.matchType == "merchant" ? "merchant is “\(r.pattern)”" : "\(r.field) \(r.matchType) “\(r.pattern)”").lineLimit(1)
                }
                TableColumn("Amount") { r in Text(amountText(r)).monospacedDigit().foregroundStyle(Ink.secondary) }.width(140)
                TableColumn("Then") { r in
                    Text((r.categoryName ?? "Uncategorized") + (r.subcategoryName.map { " › \($0)" } ?? ""))
                }
                TableColumn("") { r in
                    HStack {
                        Button("Edit") { editing = RuleDraft(r) }
                        Button(role: .destructive) { Task { await model.write { try $0.deleteRule(id: r.id) }; await load() } } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .width(80)
            }
            .frame(minHeight: 280)
            HStack {
                Button("Apply to Uncategorized") { Task { await model.applyRules() } }
                Button("Re-apply to All Rows") { Task { if let n = await model.write({ try $0.applyRules(all: true) }) { model.notice = "Rules updated \(n) transactions." } } }
                    .help("Overwrites categories on every row that matches a rule")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
            }
        }
        .padding(20)
        .frame(width: 860)
        .task(id: model.revision) { await load() }
        .sheet(item: $editing) { d in RuleEditor(draft: d).themedControls() }
        .alert("Rules learned", isPresented: Binding(get: { learned != nil }, set: { if !$0 { learned = nil } })) {
            Button("OK") { learned = nil }
        } message: {
            if let r = learned {
                Text(learnSummary(r))
            }
        }
    }

    private func load() async {
        rules = await model.run { try $0.listRules() } ?? []
    }

    private func learn() {
        Task {
            if let r = await model.write({ try $0.learnRules() }) {
                learned = r
                await load()
            }
        }
    }

    private func learnSummary(_ r: LearnRulesResult) -> String {
        var lines = ["Created \(r.created) rule\(r.created == 1 ? "" : "s"); \(r.alreadyCovered) merchant\(r.alreadyCovered == 1 ? " was" : "s were") already covered."]
        if !r.skipped.isEmpty {
            lines.append("Left to merchant memory (filed different ways): " + r.skipped.joined(separator: "; "))
        }
        lines.append(r.rowsDisagreeing == 0
            ? "All \(r.rowsChecked) categorized transactions match the rules."
            : "\(r.rowsDisagreeing) of \(r.rowsChecked) categorized transactions are filed differently than the rules would file them. Those stay as you set them.")
        return lines.joined(separator: "\n\n")
    }

    private func amountText(_ r: Rule) -> String {
        switch (r.minCents, r.maxCents) {
        case let (nil, b?) where b == -1: "money out"
        case let (a?, nil) where a == 1: "money in"
        case let (a?, b?) where a == b: "= \(Money.format(a))"
        case let (a?, b?): "\(Money.format(a)) to \(Money.format(b))"
        case let (a?, nil): "≥ \(Money.format(a))"
        case let (nil, b?): "≤ \(Money.format(b))"
        default: "any"
        }
    }

    private func toggle(_ r: Rule, _ on: Bool) {
        let input = RuleInput(priority: r.priority, enabled: on, matchType: r.matchType, field: r.field, pattern: r.pattern,
                              categoryId: r.categoryId, subcategoryId: r.subcategoryId, minCents: r.minCents, maxCents: r.maxCents)
        Task { await model.write { try $0.updateRule(id: r.id, input: input) } }
    }
}

struct RuleDraft: Identifiable {
    var id = UUID().uuidString
    var ruleId: String?
    var priority = 100
    var enabled = true
    var matchType = "contains"
    var field = "description"
    var pattern = ""
    var categoryId: String?
    var subcategoryId: String?
    var minCents: Int64?
    var maxCents: Int64?

    init() {}
    init(_ r: Rule) {
        ruleId = r.id; priority = Int(r.priority); enabled = r.enabled; matchType = r.matchType; field = r.field
        pattern = r.pattern; categoryId = r.categoryId; subcategoryId = r.subcategoryId; minCents = r.minCents; maxCents = r.maxCents
    }
}

struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: RuleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.ruleId == nil ? "New rule" : "Edit rule").font(Font.app(.title3).weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                Picker("Field", selection: $draft.field) {
                    Text("Description").tag("description")
                    Text("Merchant").tag("merchant")
                }
                Picker("Match", selection: $draft.matchType) {
                    Text("Same merchant as").tag("merchant")
                    Text("Contains").tag("contains")
                    Text("Starts with").tag("starts")
                    Text("Is exactly").tag("exact")
                    Text("Regular expression").tag("regex")
                }
                TextField("Pattern", text: $draft.pattern)
                MoneyField(title: "Minimum amount (optional)", cents: $draft.minCents)
                MoneyField(title: "Maximum amount (optional)", cents: $draft.maxCents)
                Text("Amounts are signed: money out is negative. For one exact amount, set both to the same value.")
                    .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                CategoryPicker(categoryId: $draft.categoryId, subcategoryId: $draft.subcategoryId)
                Stepper("Priority \(draft.priority)", value: $draft.priority, in: 0...1000, step: 5)
                Toggle("Enabled", isOn: $draft.enabled)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(draft.pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private func save() {
        let d = draft
        let input = RuleInput(priority: Int64(d.priority), enabled: d.enabled, matchType: d.matchType, field: d.field, pattern: d.pattern,
                              categoryId: d.categoryId, subcategoryId: d.subcategoryId, minCents: d.minCents, maxCents: d.maxCents)
        Task {
            let ok = await model.write { l -> Bool in
                if let id = d.ruleId { try l.updateRule(id: id, input: input) } else { _ = try l.createRule(input: input) }
                return true
            }
            if ok == true { dismiss() }
        }
    }
}

// MARK: - Split

struct SplitRow: Identifiable {
    let id = UUID()
    var cents: Int64?
    var categoryId: String?
    var subcategoryId: String?
    var notes = ""
}

/// Split one bank charge into parts with their own categories. The parts must add up to the charge.
struct SplitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tx: Transaction

    @State private var rows: [SplitRow] = []
    @State private var total: Int64 = 0
    @State private var isSplit = false
    @State private var loaded = false

    private var assigned: Int64 { rows.reduce(0) { $0 + abs($1.cents ?? 0) } }
    private var remaining: Int64 { total - assigned }
    private var canSave: Bool { rows.count >= 2 && remaining == 0 && rows.allSatisfy { ($0.cents ?? 0) != 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Split transaction").font(Font.app(.title3).weight(.semibold))
                Text("\(tx.displayName) · \(Dates.medium(tx.date)) · \(Money.format(total))").foregroundStyle(Ink.secondary)
            }
            .padding([.horizontal, .top], 20)
            Form {
                ForEach($rows) { $row in
                    Section {
                        MoneyField(title: "Amount", cents: $row.cents)
                        CategoryPicker(categoryId: $row.categoryId, subcategoryId: $row.subcategoryId)
                        TextField("Note", text: $row.notes, prompt: Text("Optional, e.g. prescription"))
                        if rows.count > 2 {
                            Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: { Label("Remove Part", systemImage: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    } header: {
                        Text("Part \((rows.firstIndex { $0.id == row.id } ?? 0) + 1)")
                    }
                }
                Button { rows.append(SplitRow(cents: remaining > 0 ? remaining : nil)) } label: { Label("Add Part", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            .formStyle(.grouped)
            .opacity(loaded ? 1 : 0)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Assigned \(Money.format(assigned)) of \(Money.format(total))").monospacedDigit()
                    Text(remaining == 0 ? "Fully assigned" : remaining > 0 ? "\(Money.format(remaining)) left to assign" : "\(Money.format(-remaining)) too much")
                        .font(Font.app(.callout).weight(.semibold)).foregroundStyle(remaining == 0 ? Color.positive : Color.warning)
                }
                Spacer()
                if isSplit {
                    Button("Undo Split") {
                        let id = tx.id
                        Task { if await model.write({ try $0.unsplitTransaction(id: id) }) != nil { dismiss() } }
                    }
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Split", action: save).keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
        .task { await load() }
    }

    private func load() async {
        let id = tx.id
        let parts = await model.run { try $0.splitParts(id: id) } ?? [tx]
        isSplit = parts.count > 1 || tx.splitOf != nil
        total = abs(parts.reduce(0) { $0 + $1.amountCents })
        if isSplit {
            rows = parts.map { SplitRow(cents: abs($0.amountCents), categoryId: $0.categoryId, subcategoryId: $0.subcategoryId, notes: $0.notes) }
        } else {
            // Start with everything in the current category plus an empty second part.
            rows = [SplitRow(cents: total, categoryId: tx.categoryId, subcategoryId: tx.subcategoryId, notes: tx.notes), SplitRow()]
        }
        loaded = true
    }

    private func save() {
        let sign: Int64 = tx.amountCents < 0 ? -1 : 1
        let parts = rows.map { SplitPart(amountCents: sign * abs($0.cents ?? 0), categoryId: $0.categoryId, subcategoryId: $0.subcategoryId, notes: $0.notes) }
        let id = tx.id
        Task {
            if await model.write({ try $0.splitTransaction(id: id, parts: parts) }) != nil { dismiss() }
        }
    }
}
