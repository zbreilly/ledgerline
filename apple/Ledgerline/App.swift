import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@main
struct LedgerlineApp: App {
    @State private var model = AppModel()

    init() {
        // One main window, so the tab commands macOS would add to the View and Window menus are only clutter.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup("Ledgerline", id: WindowID.main) {
            RootView()
                .frame(minWidth: 1000, minHeight: 640)
                .themedRoot()
                .environment(model)
                // A CSV opened with the app (Dock drop, Open With) goes to the import preview.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    model.pendingImport = url
                    model.page = .import
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1280, height: 820)
        .commands { LedgerlineCommands(model: model) }

        // Colors, fonts, outlines, panel art and button skins.
        Window("Appearance", id: WindowID.appearance) {
            AppearanceView()
                .themedControls()
                .themedRoot()
                .environment(model)
        }
        .defaultSize(width: 820, height: 700)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case dashboard, transactions, calendar, debts, investments, planning, categories, accounts, `import`, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .transactions: "Transactions"
        case .calendar: "Cash Flow"
        case .debts: "Debt"
        case .investments: "Investments"
        case .categories: "Categories"
        case .planning: "Planning"
        case .accounts: "Accounts"
        case .import: "Import"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .transactions: "list.bullet.rectangle"
        case .calendar: "calendar"
        case .debts: "creditcard.trianglebadge.exclamationmark"
        case .investments: "chart.line.uptrend.xyaxis"
        case .categories: "tag"
        case .planning: "target"
        case .accounts: "creditcard"
        case .import: "square.and.arrow.down"
        case .settings: "gearshape"
        }
    }
}

/// A filter another page can hand to the Transactions page.
struct TxPreset: Equatable {
    var uncategorizedOnly = false
    var categoryId: String? = nil
    var month: String? = nil
}

@MainActor
@Observable
final class AppModel {
    var ledger: Ledger?
    var dbPath: String?
    var accounts: [Account] = []
    var categories: [Category] = []
    var meta: Meta?
    var settings: AppSettings?
    /// Net worth across cash, investments, and debts (as of today).
    var overview: FinancialOverview?
    /// nil = all accounts
    var activeAccount: String?
    var month: String = currentMonth()
    var page: Page = .dashboard
    /// Bumped after any write so pages reload.
    var revision = 0
    var errorMessage: String?
    var notice: String?
    var txPreset: TxPreset?
    /// A menu command waiting for its page to carry it out.
    var pendingCommand: AppCommand?
    /// A CSV file waiting for the Import page to pick it up.
    var pendingImport: URL?

    static let dbPathKey = "databasePath"

    init() {
        ShellPath.apply()
        if let p = Self.initialPath() { open(path: p) }
    }

    /// LEDGERLINE_DB env var, then the last database used. nil = show the welcome screen.
    static func initialPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["LEDGERLINE_DB"], !env.isEmpty { return env }
        if let saved = UserDefaults.standard.string(forKey: dbPathKey), FileManager.default.fileExists(atPath: saved) { return saved }
        return nil
    }

    static var defaultNewPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Ledgerline/ledgerline.db").path
    }

    var colorScheme: ColorScheme? {
        switch settings?.theme {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    var reloadKey: String { "\(revision)|\(month)|\(activeAccount ?? "all")" }

    func open(path: String) {
        do {
            ledger = try Ledger.open(path: path)
            LocalAI.apply(to: ledger)
            dbPath = path
            if ProcessInfo.processInfo.environment["LEDGERLINE_DB"] == nil {
                UserDefaults.standard.set(path, forKey: Self.dbPathKey)
            }
            activeAccount = nil
            reloadShared()
        } catch {
            errorMessage = "Could not open the database at \(path).\n\n\(describe(error))"
        }
    }

    func reloadShared() {
        guard let ledger else { return }
        do {
            accounts = try ledger.listAccounts()
            categories = try ledger.listCategories()
            meta = try ledger.meta()
            settings = try ledger.getSettings()
            overview = try ledger.financialOverview()
            if let a = activeAccount, !accounts.contains(where: { $0.id == a }) { activeAccount = nil }
        } catch {
            errorMessage = describe(error)
        }
        revision += 1
    }

    /// Runs core work off the main thread. Errors become an alert; returns nil on failure.
    func run<T: Sendable>(_ work: @escaping @Sendable (Ledger) throws -> T) async -> T? {
        guard let ledger else { return nil }
        do {
            return try await Task.detached(priority: .userInitiated) { try work(ledger) }.value
        } catch {
            errorMessage = describe(error)
            return nil
        }
    }

    /// Like `run`, then refreshes shared data so every page sees the change.
    @discardableResult
    func write<T: Sendable>(_ work: @escaping @Sendable (Ledger) throws -> T) async -> T? {
        let r = await run(work)
        reloadShared()
        return r
    }

    func applyRules() async {
        if let n = await write({ try $0.applyRules(all: false) }) { notice = "Rules categorized \(n) transaction\(n == 1 ? "" : "s")." }
    }

    func applyMemory() async {
        if let n = await write({ try $0.applyMerchantMemory() }) { notice = "Merchant memory categorized \(n) transaction\(n == 1 ? "" : "s")." }
    }

    func showTransactions(_ preset: TxPreset) {
        txPreset = preset
        page = .transactions
    }

    func chooseExistingDatabase() {
        let panel = NSOpenPanel()
        panel.title = "Open a Ledgerline database"
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data, .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(path: url.path) }
    }

    func createNewDatabase() {
        let panel = NSSavePanel()
        panel.title = "Create a new Ledgerline database"
        panel.nameFieldStringValue = "ledgerline.db"
        let dir = URL(fileURLWithPath: Self.defaultNewPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        panel.directoryURL = dir
        if panel.runModal() == .OK, let url = panel.url { open(path: url.path) }
    }
}

/// AI settings live in this Mac's preferences, not in the database file, so a database
/// from somewhere else can't choose which command runs.
enum LocalAI {
    private static let provider = "aiProvider", model = "aiModel", timeout = "aiTimeoutSec"

    static func apply(to ledger: Ledger?) {
        let d = UserDefaults.standard
        let t = d.integer(forKey: timeout)
        // A provider that is no longer offered falls back to the default (claude).
        try? ledger?.setAiSettings(provider: d.string(forKey: provider) ?? "claude", model: d.string(forKey: model) ?? "",
                                   timeoutSec: UInt32(clamping: t > 0 ? t : 240))
    }

    static func save(_ s: AppSettings) {
        let d = UserDefaults.standard
        d.set(s.aiProvider, forKey: provider)
        d.set(s.aiModel, forKey: model)
        d.set(Int(s.aiTimeoutSec), forKey: timeout)
        d.removeObject(forKey: "aiCustomCommand")
    }
}

/// Apps opened from Finder get a minimal PATH, which hides Homebrew/nvm installs of the
/// claude/codex CLIs used by AI Sort. Borrow the login shell's PATH.
enum ShellPath {
    static func apply() {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs: [String] = []
        if let s = loginShellPath() { dirs += s.split(separator: ":").map(String.init) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.volta/bin", home + "/.local/bin", home + "/.claude/local"]
        dirs += (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let path = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        setenv("PATH", path, 1)
    }

    private static func loginShellPath() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "printf '__LLPATH__%s' \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let r = out.range(of: "__LLPATH__") else { return nil }
        let path = String(out[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.ledger == nil {
                WelcomeView().themedControls()
            } else {
                NavigationSplitView {
                    Sidebar()
                        .themedControls()
                        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
                } detail: {
                    detail
                        .themedControls()
                        .background(WindowBackdrop())
                        .navigationTitle(model.page.title)
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.page {
        case .dashboard: DashboardView()
        case .transactions: TransactionsView()
        case .calendar: CashFlowView()
        case .debts: DebtsView()
        case .investments: InvestmentsView()
        case .categories: CategoriesView()
        case .planning: PlanningView()
        case .accounts: AccountsView()
        case .import: ImportView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            List(selection: Binding(get: { Optional(model.page) }, set: { if let p = $0 { model.page = p } })) {
                Section {
                    Picker("Viewing", selection: $model.activeAccount) {
                        Text("All accounts").tag(String?.none)
                        ForEach(model.accounts) { a in Text(a.name).tag(Optional(a.id)) }
                    }
                    .labelsHidden()
                }
                Section {
                    ForEach(Page.allCases) { p in
                        Label {
                            HStack {
                                Text(p.title)
                                Spacer()
                                if p == .transactions, let n = model.meta?.uncategorized, n > 0 {
                                    Text("\(n)").font(Font.app(.caption2).monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.warning.opacity(0.25), in: Capsule())
                                        .help("\(n) uncategorized")
                                }
                            }
                        } icon: { Image(systemName: p.symbol).themedAccent() }
                        .tag(p)
                    }
                }
                Section("Accounts") {
                    ForEach(model.accounts.filter { !InvestmentKinds.isInvestment($0.kind) }) { a in
                        accountRow(a)
                    }
                }
                Section {
                    ForEach(model.accounts.filter { InvestmentKinds.isInvestment($0.kind) }) { a in
                        accountRow(a)
                    }
                    if !model.accounts.contains(where: { InvestmentKinds.isInvestment($0.kind) }) {
                        Text("None yet").foregroundStyle(Ink.secondary)
                    }
                } header: {
                    HStack {
                        Text("Investments")
                        Spacer()
                        Text(Money.format(investments, compact: true)).monospacedDigit()
                    }
                }
            }
            .listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Cash").foregroundStyle(Ink.secondary)
                    Spacer()
                    Text(Money.format(liquid)).monospacedDigit()
                }
                HStack {
                    Text("Investments").foregroundStyle(Ink.secondary)
                    Spacer()
                    Text(Money.format(investments)).monospacedDigit()
                }
                HStack {
                    Text("Debt").foregroundStyle(Ink.secondary)
                    Spacer()
                    Text(Money.format(-(model.overview?.debtCents ?? 0))).monospacedDigit().foregroundStyle(Color.negative)
                }
                Divider().padding(.vertical, 2)
                HStack {
                    Text("Net worth").fontWeight(.semibold)
                    Spacer()
                    let nw = model.overview?.netWorthCents ?? 0
                    Text(Money.format(nw)).monospacedDigit().fontWeight(.semibold).foregroundStyle(nw < 0 ? Color.negative : Color.themeText)
                }
                .help("Cash + investments − all debts. Details on the Dashboard.")
            }
            .font(Font.app(.caption))
            .padding(12)
        }
        .background(SidebarBackdrop())
    }

    private var liquid: Int64 {
        model.accounts.filter { ["checking", "savings", "cash"].contains($0.kind) }.reduce(0) { $0 + $1.displayBalanceCents }
    }

    private var investments: Int64 {
        model.accounts.filter { InvestmentKinds.isInvestment($0.kind) }.reduce(0) { $0 + $1.displayBalanceCents }
    }

    private func accountRow(_ a: Account) -> some View {
        HStack {
            Circle().fill(Color(hex: a.color)).frame(width: 8, height: 8)
            Text(a.name).lineLimit(1)
            Spacer()
            if (a.kind == "credit" || a.kind == "loan") && !a.balanceSet {
                Text("Not set").font(Font.app(.caption)).foregroundStyle(Color.warning)
                    .help("Imports show activity, not the balance. Set the real balance on the Accounts page.")
            } else {
                Text(Money.format(a.displayBalanceCents, compact: true))
                    .font(Font.app(.caption).monospacedDigit())
                    .foregroundStyle(a.displayBalanceCents < 0 ? Color.negative : Color.themeSecondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if InvestmentKinds.isInvestment(a.kind) { model.page = .investments } else { model.activeAccount = a.id }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Welcome to Ledgerline").font(Font.app(.largeTitle).weight(.semibold))
            Text("Local-first personal finance. Your data stays in one SQLite file on this Mac.")
                .foregroundStyle(Ink.secondary)
            HStack(spacing: 12) {
                Button("Open Existing Database…") { model.chooseExistingDatabase() }
                    .buttonStyle(.themedProminent)
                Button("Create New Database…") { model.createNewDatabase() }
            }
            .controlSize(.large)
            Text("A database from the earlier Ledgerline app works as is (for example ledgerline/data/ledgerline.db).")
                .font(Font.app(.caption))
                .foregroundStyle(Ink.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackdrop())
    }
}
