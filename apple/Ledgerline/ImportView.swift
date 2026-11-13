import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(AppModel.self) private var model

    @State private var text: String?
    @State private var filename = ""
    @State private var preview: ImportPreview?
    @State private var mapping = ColumnMapping(date: nil, description: nil, merchant: nil, amount: nil, debit: nil, credit: nil,
                                               notes: nil, txnType: nil, category: nil, checkNumber: nil, balance: nil)
    @State private var accountId: String?
    @State private var newAccountName = ""
    @State private var newAccountKind = "checking"
    @State private var dateFormat = "auto"
    @State private var invert = false
    @State private var skipDuplicates = true
    @State private var applyRules = true
    @State private var importing = false
    @State private var result: ImportResult?
    @State private var batches: [ImportBatch] = []
    @State private var undoing: ImportBatch?
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = result { resultPanel(r) }
                if let p = preview {
                    mappingPanel(p)
                    samplePanel(p)
                } else {
                    dropZone
                }
                historyPanel
            }
            .padding(20)
        }
        .task(id: model.revision) { batches = await model.run { try $0.listImportBatches() } ?? [] }
        .onAppear(perform: consumePending)
        .onChange(of: model.pendingImport) { _, _ in consumePending() }
        .confirmationDialog("Undo this import?", isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } })) {
            Button("Delete \(undoing?.txCount ?? 0) Transactions", role: .destructive) {
                let id = undoing?.id ?? ""
                undoing = nil
                Task {
                    if let n = await model.write({ try $0.deleteImportBatch(id: id) }) { model.notice = "Removed \(n) transactions." }
                }
            }
        } message: {
            Text("Deletes every transaction that came from \(undoing?.filename ?? "this file"), including any categories you set on them.")
        }
    }

    // MARK: - Step 1: choose a file

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(Ink.secondary)
            Text("Drop a bank CSV here").font(Font.app(.title3).weight(.semibold))
            Text("Any bank works: Chase, Capital One, and others. Columns are detected automatically and you can adjust them.")
                .foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            Button("Choose CSV File…", action: choose).buttonStyle(.themedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(dropTargeted ? Color.themeAccent : Color.themeSecondary.opacity(0.4)))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in load(url) } }
            }
            return true
        }
    }

    private func consumePending() {
        guard let url = model.pendingImport else { return }
        model.pendingImport = nil
        load(url)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, UTType(filenameExtension: "csv") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func load(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            model.errorMessage = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let t = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        text = t
        filename = url.lastPathComponent
        result = nil
        accountId = model.activeAccount ?? guessAccount(url.lastPathComponent)
        Task {
            if let p = await model.run({ try $0.previewImport(text: t, mapping: nil, dateFormat: "auto") }) {
                preview = p
                mapping = p.mapping
            }
        }
    }

    /// "capitalone1234_2026-01-15.csv" -> the account whose name contains "1234".
    private func guessAccount(_ file: String) -> String? {
        let digits = file.split(whereSeparator: { !$0.isNumber }).map(String.init).filter { $0.count == 4 }
        for d in digits {
            if let a = model.accounts.first(where: { $0.name.contains(d) }) { return a.id }
        }
        let lower = file.lowercased()
        return model.accounts.first { a in
            a.name.lowercased().split(separator: " ").first.map { lower.contains($0) } ?? false
        }?.id
    }

    private func refreshPreview() {
        guard let t = text else { return }
        let m = mapping, f = dateFormat
        Task { if let p = await model.run({ try $0.previewImport(text: t, mapping: m, dateFormat: f) }) { preview = p } }
    }

    // MARK: - Step 2: map columns and pick an account

    private func mappingPanel(_ p: ImportPreview) -> some View {
        Panel(title: "\(filename): \(p.total) rows", trailing: AnyView(Button("Choose Another File") { reset() })) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    columnPicker("Date", \.date, p.headers)
                    columnPicker("Description", \.description, p.headers)
                    columnPicker("Merchant", \.merchant, p.headers)
                }
                GridRow {
                    columnPicker("Amount", \.amount, p.headers)
                    columnPicker("Debit (money out)", \.debit, p.headers)
                    columnPicker("Credit (money in)", \.credit, p.headers)
                }
                GridRow {
                    columnPicker("Notes", \.notes, p.headers)
                    Picker("Date format", selection: $dateFormat) {
                        Text("Automatic").tag("auto")
                        Text("Month/Day/Year").tag("mdy")
                        Text("Day/Month/Year").tag("dmy")
                    }
                    .onChange(of: dateFormat) { _, _ in refreshPreview() }
                    Toggle("Flip signs (bank shows spending as positive)", isOn: $invert)
                }
            }
            Divider()
            HStack(spacing: 16) {
                Picker("Into account", selection: $accountId) {
                    Text("New account…").tag(String?.none)
                    ForEach(model.accounts) { a in Text(a.name).tag(Optional(a.id)) }
                }
                .frame(width: 300)
                if accountId == nil {
                    TextField("New account name", text: $newAccountName).frame(width: 200)
                    Picker("Type", selection: $newAccountKind) {
                        Text("Checking").tag("checking")
                        Text("Savings").tag("savings")
                        Text("Credit card").tag("credit")
                        Text("Loan").tag("loan")
                    }
                    .frame(width: 180)
                }
            }
            HStack(spacing: 16) {
                Toggle("Skip duplicates", isOn: $skipDuplicates)
                    .help("Skips rows already imported, even if the bank changed the description format")
                Toggle("Apply rules", isOn: $applyRules)
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Button("Import \(p.total) Rows", action: commit)
                    .buttonStyle(.themedProminent)
                    .disabled(importing || (accountId == nil && newAccountName.trimmingCharacters(in: .whitespaces).isEmpty) || mapping.date == nil)
            }
            Text("After import: card payments and transfers are flagged automatically, then rules run, then merchant memory fills in categories you've used before.")
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
        }
    }

    private func columnPicker(_ title: String, _ key: WritableKeyPath<ColumnMapping, UInt32?>, _ headers: [String]) -> some View {
        Picker(title, selection: Binding(get: { mapping[keyPath: key] }, set: { mapping[keyPath: key] = $0; refreshPreview() })) {
            Text("—").tag(UInt32?.none)
            ForEach(Array(headers.enumerated()), id: \.offset) { i, h in Text(h.isEmpty ? "Column \(i + 1)" : h).tag(Optional(UInt32(i))) }
        }
    }

    private func samplePanel(_ p: ImportPreview) -> some View {
        Panel(title: "Preview (first \(p.sample.count) rows)") {
            Table(p.sample) {
                TableColumn("Line") { r in Text("\(r.line)").foregroundStyle(Ink.secondary).monospacedDigit() }.width(40)
                TableColumn("Date") { r in
                    if let d = r.parsedDate { Text(Dates.medium(d)).monospacedDigit() } else { Text(r.date.isEmpty ? "missing" : "bad: \(r.date)").foregroundStyle(Color.negative) }
                }
                .width(110)
                TableColumn("Description") { r in Text(r.description).lineLimit(1) }
                TableColumn("Amount") { r in
                    if let c = r.parsedCents { AmountText(cents: invert ? -c : c) } else { Text("bad").foregroundStyle(Color.negative) }
                }
                .width(100)
            }
            .frame(height: 320)
        }
    }

    private func commit() {
        guard let t = text else { return }
        let req = ImportRequest(text: t, filename: filename, accountId: accountId,
                                newAccount: accountId == nil ? NewAccount(name: newAccountName, institution: "", kind: newAccountKind,
                                                                          balanceCents: 0, color: "#6d7cff", dueDay: 0) : nil,
                                mapping: mapping, dateFormat: dateFormat, invert: invert, skipDuplicates: skipDuplicates, applyRules: applyRules)
        importing = true
        Task {
            let r = await model.write { try $0.commitImport(request: req) }
            importing = false
            if let r {
                result = r
                preview = nil
                text = nil
            }
        }
    }

    private func reset() {
        preview = nil
        text = nil
        result = nil
    }

    // MARK: - Result and history

    private func resultPanel(_ r: ImportResult) -> some View {
        Panel(title: "Import complete") {
            HStack(spacing: 12) {
                StatCard(title: "Imported", value: "\(r.imported)", tint: Color.positive)
                StatCard(title: "Skipped as duplicates", value: "\(r.skipped)",
                         detail: r.pendingDuplicatesSkipped > 0 ? "\(r.pendingDuplicatesSkipped) were pending charges already on file" : nil)
                StatCard(title: "Transfers flagged", value: "\(r.transfersMarked)")
                StatCard(title: "Categorized by rules", value: "\(r.rulesApplied)")
                StatCard(title: "Categorized by memory", value: "\(r.remembered)")
                if let b = r.balanceUpdatedCents {
                    StatCard(title: "Balance updated", value: Money.format(b), detail: r.balanceAsOf.map { "From the file, as of \(Dates.medium($0))" })
                }
            }
            ForEach(r.errors, id: \.self) { e in Text(e).foregroundStyle(Color.negative).font(Font.app(.caption)) }
            HStack {
                Button("Review Uncategorized") { model.showTransactions(TxPreset(uncategorizedOnly: true)) }
                Button("Import Another File") { result = nil }
            }
        }
    }

    private var historyPanel: some View {
        Panel(title: "Import history") {
            if batches.isEmpty {
                Text("No imports yet.").foregroundStyle(Ink.secondary)
            }
            ForEach(batches) { b in
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(Ink.secondary)
                    VStack(alignment: .leading) {
                        Text(b.filename)
                        Text("\(b.accountName ?? "Deleted account") · \(b.importedAt) UTC").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                    Spacer()
                    Text("\(b.txCount) rows, \(b.skipped) skipped").foregroundStyle(Ink.secondary).monospacedDigit()
                    Button("Undo…") { undoing = b }.disabled(b.txCount == 0)
                }
                Divider()
            }
        }
    }
}
