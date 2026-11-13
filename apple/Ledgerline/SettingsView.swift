import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var draft: AppSettings?
    @State private var status: AiStatus?
    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmWipe = false
    @State private var wipeText = ""

    var body: some View {
        Form {
            Section("Database") {
                LabeledContent("File") {
                    Text(model.dbPath ?? "").textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                if let m = model.meta {
                    LabeledContent("Contents", value: "\(m.accounts) accounts, \(m.transactions) transactions, \(m.categories) categories")
                    LabeledContent("Core version", value: m.version)
                }
                HStack {
                    Button("Show in Finder") { if let p = model.dbPath { revealInFinder(p) } }
                    Button("Open Another Database…") { model.chooseExistingDatabase() }
                    Button("Create New Database…") { model.createNewDatabase() }
                }
                Text("The database stays compatible with the earlier Ledgerline app, so both can use the same file.")
                    .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            }

            if let d = Binding($draft) {
                Section("Appearance") {
                    let themes = ThemeStore.shared
                    Picker("Profile", selection: Binding(get: { themes.theme.id }, set: { themes.select($0) })) {
                        Section("Built in") {
                            ForEach(Theme.builtIns) { Text($0.name).tag($0.id) }
                        }
                        if !themes.profiles.isEmpty {
                            Section("Saved") {
                                ForEach(themes.profiles) { Text($0.name).tag($0.id) }
                            }
                        }
                        if !themes.isSaved(themes.theme.id) && !themes.theme.isBuiltIn {
                            Section("Not saved yet") { Text(themes.theme.name).tag(themes.theme.id) }
                        }
                    }
                    .disabled(themes.isDirty)
                    Picker("Light or dark", selection: d.theme) {
                        Text("Match system").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .disabled(!themes.theme.isSystem)
                    HStack {
                        Button("Customize Appearance…") { openWindow(id: WindowID.appearance) }
                        Text(themes.isDirty ? "\(themes.theme.name) has changes that aren't saved. Save or revert them in the Appearance window to switch profiles."
                             : themes.theme.isSystem ? "Colors, fonts, outlines, panel art and custom buttons."
                             : "Light or dark follows the profile's window color.")
                            .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    }
                }

                Section("AI categorization") {
                    Picker("Provider", selection: d.aiProvider) {
                        Text("Anthropic: Claude Code (claude)").tag("claude")
                        Text("OpenAI: Codex (codex)").tag("codex")
                    }
                    if let s = status {
                        LabeledContent("Installed") {
                            HStack(spacing: 10) {
                                cli("claude", s.claude)
                                cli("codex", s.codex)
                            }
                        }
                    }
                    TextField("Model (optional)", text: d.aiModel, prompt: Text("Provider default"))
                    Stepper("Timeout: \(d.wrappedValue.aiTimeoutSec) seconds", value: d.aiTimeoutSec, in: 30...900, step: 30)
                    HStack {
                        Button("Test Connection") { test() }.disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        if let t = testResult { Text(t).foregroundStyle(Ink.secondary).lineLimit(2) }
                    }
                    Text("AI Sort sends transaction descriptions and amounts to the CLI you choose, with its tools turned off (Codex runs in its read-only sandbox). It only touches uncategorized rows unless you select rows yourself. These settings are saved on this Mac, not in the database.")
                        .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                }
                .onChange(of: draft) { old, new in
                    if old != nil, let new { save(new) }
                }
            }

            Section("Data") {
                HStack {
                    Button("Export Transactions as CSV…") { model.exportTransactionsCSV() }
                    Button("Re-run Merchant Memory") { Task { await model.applyMemory() } }
                    Button("Apply Rules to Uncategorized") { Task { await model.applyRules() } }
                }
                Button("Erase Everything…", role: .destructive) { wipeText = ""; confirmWipe = true }
                    .help("Deletes all accounts, transactions, categories, rules, and budgets")
            }
        }
        .formStyle(.grouped)
        .task(id: model.revision) {
            if draft == nil {
                var s = model.settings
                if s?.theme.isEmpty == true { s?.theme = "system" }
                draft = s
            }
            if status == nil { status = await model.run { try $0.aiStatus() } }
        }
        .sheet(isPresented: $confirmWipe) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Erase everything?").font(Font.app(.headline))
                Text("This deletes every account, transaction, category, rule, and budget in this database. It can't be undone. Type ERASE to confirm.")
                    .foregroundStyle(Ink.secondary)
                TextField("ERASE", text: $wipeText)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmWipe = false }.keyboardShortcut(.cancelAction)
                    Button("Erase", role: .destructive) {
                        confirmWipe = false
                        Task { await model.write { try $0.wipeAll() } }
                    }
                    .disabled(wipeText != "ERASE")
                }
            }
            .padding(20)
            .frame(width: 420)
            .themedControls()
        }
    }

    private func cli(_ name: String, _ path: String?) -> some View {
        Label(name, systemImage: path == nil ? "xmark.circle" : "checkmark.circle.fill")
            .foregroundStyle(path == nil ? Color.themeSecondary : Color.positive)
            .help(path ?? "Not found on PATH")
    }

    private func save(_ s: AppSettings) {
        Task {
            // Only remember AI settings the core accepted.
            if await model.write({ try $0.saveSettings(settings: s) }) != nil { LocalAI.save(s) }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            let r = await model.run { try $0.aiTest() }
            testing = false
            if let r { testResult = (r.ok ? "Working. " : "Unexpected reply: ") + "\(r.reply) (\(r.elapsedMs / 1000)s)" }
        }
    }
}
