import SwiftUI

struct CategoriesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CategoryDraft?
    @State private var deleting: Category?
    @State private var addingSubTo: Category?
    @State private var showNewSub = false
    @State private var renamingSub: Subcategory?
    @State private var deletingSub: Subcategory?
    @State private var confirmRestore = false
    @State private var showDesigner = false

    var body: some View {
        List {
            Section {
                Text("Categories organize spending and income. Transfers are excluded from every report, so a Transfers category is only a label.")
                    .foregroundStyle(Ink.secondary)
            }
            ForEach(model.categories) { c in
                DisclosureGroup {
                    ForEach(c.subcategories) { s in
                        HStack {
                            Text(s.name)
                            Spacer()
                            Text("\(s.txCount)").monospacedDigit().foregroundStyle(Ink.secondary)
                            Menu {
                                Button("Rename…") { renamingSub = s }
                                Button("Delete…", role: .destructive) { deletingSub = s }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    Button { addingSubTo = c } label: { Label("Add subcategory", systemImage: "plus") }
                        .buttonStyle(.borderless)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: c.color)).frame(width: 6, height: 22)
                        Text(c.icon == "folder" ? "📁" : c.icon)
                        Text(c.name).font(Font.app(.body).weight(.medium))
                        if c.kind == "income" {
                            Text("Income").font(Font.app(.caption)).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.positive.opacity(0.2), in: Capsule())
                        }
                        Spacer()
                        Text("\(c.txCount) tx").foregroundStyle(Ink.secondary).monospacedDigit()
                        Text(Money.format(c.kind == "income" ? c.inCents : -c.outCents)).monospacedDigit().frame(width: 110, alignment: .trailing)
                        Menu {
                            Button("Add Subcategory…") { addingSubTo = c }
                            Button("Edit…") { editing = CategoryDraft(c) }
                            Button("Show Transactions") { model.showTransactions(TxPreset(categoryId: c.id)) }
                            Divider()
                            Button("Delete…", role: .destructive) { deleting = c }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { editing = CategoryDraft() } label: { Label("New Category", systemImage: "plus") }.buttonStyle(.automatic)
                Button { showNewSub = true } label: { Label("New Subcategory", systemImage: "plus.square.on.square") }.buttonStyle(.automatic)
                    .help("Add a subcategory to any category")
                Button { showDesigner = true } label: { Label("AI Designer", systemImage: "sparkles") }.buttonStyle(.automatic)
                    .help("AI taxonomy designer")
                Button { confirmRestore = true } label: { Label("Restore Defaults", systemImage: "arrow.counterclockwise") }.buttonStyle(.automatic)
                    .help("Add the standard starter taxonomy")
            }
        }
        .onCommand(.newCategory, .newSubcategory, .categoryDesigner) { command in
            switch command {
            case .newSubcategory: showNewSub = true
            case .categoryDesigner: showDesigner = true
            default: editing = CategoryDraft()
            }
        }
        .sheet(item: $editing) { d in CategoryEditor(draft: d).themedControls() }
        .sheet(item: $deleting) { c in DeleteCategorySheet(category: c).themedControls() }
        .sheet(item: $deletingSub) { s in DeleteSubcategorySheet(sub: s).themedControls() }
        .sheet(isPresented: $showDesigner) { TaxonomyDesigner().themedControls() }
        .sheet(isPresented: $showNewSub) { NewSubcategorySheet().themedControls() }
        .sheet(item: $addingSubTo) { c in
            NameSheet(title: "New subcategory in \(c.name)", initial: "") { name in
                Task { await model.write { try $0.createSubcategory(categoryId: c.id, name: name) } }
            }
        }
        .sheet(item: $renamingSub) { s in
            NameSheet(title: "Rename subcategory", initial: s.name) { name in
                Task { await model.write { try $0.renameSubcategory(id: s.id, name: name) } }
            }
        }
        .confirmationDialog("Restore the default categories?", isPresented: $confirmRestore) {
            Button("Restore Defaults") {
                Task {
                    if let r = await model.write({ try $0.restoreDefaults() }) {
                        model.notice = "Added \(r.created) categories and \(r.subsCreated) subcategories."
                    }
                }
            }
        } message: {
            Text("This adds any stock categories that are missing by name (Dining, Transport, Health & Fitness, …). Your merged categories stay, but the stock ones you removed will come back.")
        }
    }
}

/// Pick a category and name a new subcategory under it.
struct NewSubcategorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initialCategory: String? = nil
    @State private var categoryId: String?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New subcategory").font(Font.app(.headline))
            Form {
                Picker("Category", selection: $categoryId) {
                    Text("Choose…").tag(String?.none)
                    ForEach(model.categories) { c in Text(c.name).tag(Optional(c.id)) }
                }
                TextField("Name", text: $name).onSubmit(save)
                if let c = model.categories.first(where: { $0.id == categoryId }), !c.subcategories.isEmpty {
                    Text("Already in \(c.name): " + c.subcategories.map(\.name).joined(separator: ", "))
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: save).keyboardShortcut(.defaultAction).buttonStyle(.themedDefault)
                    .disabled(categoryId == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { categoryId = initialCategory }
    }

    private func save() {
        guard let c = categoryId else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            if await model.write({ try $0.createSubcategory(categoryId: c, name: n) }) != nil { dismiss() }
        }
    }
}

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Font.app(.headline))
            TextField("Name", text: $name).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .themedControls()
        .onAppear { name = initial }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onSave(n)
        dismiss()
    }
}

struct CategoryDraft: Identifiable {
    var id = UUID().uuidString
    var categoryId: String?
    var name = ""
    var kind = "expense"
    var color = Color(hex: "#6d7cff")
    var icon = "📁"

    init() {}
    init(_ c: Category) {
        categoryId = c.id; name = c.name; kind = c.kind; color = Color(hex: c.color); icon = c.icon == "folder" ? "📁" : c.icon
    }
}

struct CategoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: CategoryDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.categoryId == nil ? "New category" : "Edit category").font(Font.app(.title3).weight(.semibold)).padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $draft.name)
                Picker("Kind", selection: $draft.kind) {
                    Text("Expense").tag("expense")
                    Text("Income").tag("income")
                }
                .pickerStyle(.segmented)
                TextField("Icon (emoji)", text: $draft.icon)
                TriangleColorField(label: "Color", selection: $draft.color)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 400)
    }

    private func save() {
        let d = draft
        let hex = d.color.hexString
        Task {
            await model.write { l in
                if let id = d.categoryId {
                    try l.updateCategory(id: id, patch: CategoryPatch(name: d.name, kind: d.kind, color: hex, icon: d.icon, sort: nil, archived: nil))
                } else {
                    _ = try l.createCategory(name: d.name, kind: d.kind, color: hex, icon: d.icon)
                }
            }
            dismiss()
        }
    }
}

struct DeleteCategorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let category: Category
    @State private var target: String?
    @State private var targetSub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(category.name)”?").font(Font.app(.headline))
            Text("\(category.txCount) transaction(s) use it. Its budgets and rules will be removed.").foregroundStyle(Ink.secondary)
            Form {
                Picker("Move its transactions to", selection: $target) {
                    Text("Uncategorized").tag(String?.none)
                    ForEach(model.categories.filter { $0.id != category.id }) { c in Text(c.name).tag(Optional(c.id)) }
                }
                if let t = target, let c = model.categories.first(where: { $0.id == t }), !c.subcategories.isEmpty {
                    Picker("Subcategory", selection: $targetSub) {
                        Text("None").tag(String?.none)
                        ForEach(c.subcategories) { s in Text(s.name).tag(Optional(s.id)) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    let id = category.id, t = target, s = target == nil ? nil : targetSub
                    Task { await model.write { try $0.deleteCategory(id: id, reassignCategory: t, reassignSub: s) }; dismiss() }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct DeleteSubcategorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sub: Subcategory
    @State private var mergeInto: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(sub.name)”?").font(Font.app(.headline))
            Text("\(sub.txCount) transaction(s) use it. They keep their category.").foregroundStyle(Ink.secondary)
            Picker("Merge into", selection: $mergeInto) {
                Text("No subcategory").tag(String?.none)
                ForEach(siblings) { s in Text(s.name).tag(Optional(s.id)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    let id = sub.id, m = mergeInto
                    Task { await model.write { try $0.deleteSubcategory(id: id, mergeInto: m) }; dismiss() }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var siblings: [Subcategory] {
        model.categories.first { $0.id == sub.categoryId }?.subcategories.filter { $0.id != sub.id } ?? []
    }
}

struct TaxonomyDesigner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var proposal: [ProposedCategory]?
    @State private var chosen = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI taxonomy designer").font(Font.app(.title3).weight(.semibold))
            Text("The AI looks at your top merchants and proposes categories. Existing categories are kept; only names that don't exist yet are added.")
                .foregroundStyle(Ink.secondary)
            if running {
                HStack { ProgressView().controlSize(.small); Text("Designing… this can take a minute.") }.frame(maxWidth: .infinity, minHeight: 240)
            } else if let p = proposal {
                List(p, selection: $chosen) { c in
                    HStack(alignment: .top) {
                        Circle().fill(Color(hex: c.color)).frame(width: 10, height: 10).padding(.top, 4)
                        VStack(alignment: .leading) {
                            Text("\(c.icon) \(c.name)").font(Font.app(.body).weight(.medium))
                            Text(c.subcategories.joined(separator: ", ")).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                        }
                        Spacer()
                        if model.categories.contains(where: { $0.name.lowercased() == c.name.lowercased() }) {
                            Text("exists").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                        }
                        Text(c.kind).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                }
                .frame(minHeight: 320)
            } else {
                Spacer().frame(height: 100)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if proposal == nil {
                    Button("Design Categories") { design() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(running)
                } else {
                    Button("Add \(chosen.count) Selected") { add() }.keyboardShortcut(.defaultAction).buttonStyle(.themedDefault).disabled(chosen.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func design() {
        running = true
        Task {
            proposal = await model.run { try $0.aiTaxonomy() }
            chosen = Set(proposal?.map(\.name) ?? [])
            running = false
        }
    }

    private func add() {
        let list = proposal?.filter { chosen.contains($0.name) } ?? []
        Task {
            if let r = await model.write({ try $0.bulkCreateCategories(categories: list) }) {
                model.notice = "Added \(r.created) categories and \(r.subsCreated) subcategories."
                dismiss()
            }
        }
    }
}
