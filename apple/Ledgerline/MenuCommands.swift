import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The menu bar. Every action in the app has a place here, grouped the way Mac menus usually are:
//   Ledgerline  settings and appearance
//   File        things that create something, and files going in or out
//   Edit        the standard editing commands, plus Find
//   View        what the window shows: sidebar, month, account, look
//   Go          the pages
//   Tools       work the app does for you: categorizing, finding, AI
//   Window      standard
//   Help        search across all of the above

enum WindowID {
    static let main = "main"
    static let appearance = "appearance"
}

// MARK: - Commands that a page carries out

/// Something a menu asks a page to do. The menu switches to the page and leaves the command
/// for it; the page picks it up when it appears (or at once, if it is already showing).
enum AppCommand: Equatable {
    case newAccount, newCategory, newSubcategory, newRecurring, newDebt, newInvestment
    case showRules, aiSort, searchTransactions
    case findDebts, findRecurring, categoryDesigner, cashBalances

    var page: Page {
        switch self {
        case .newAccount: .accounts
        case .newCategory, .newSubcategory, .categoryDesigner: .categories
        case .newRecurring, .findRecurring, .cashBalances: .calendar
        case .newDebt, .findDebts: .debts
        case .newInvestment: .investments
        case .showRules, .aiSort, .searchTransactions: .transactions
        }
    }
}

extension AppModel {
    func perform(_ command: AppCommand) {
        guard ledger != nil else { return }
        page = command.page
        pendingCommand = command
    }
}

private struct CommandReceiver: ViewModifier {
    @Environment(AppModel.self) private var model
    let commands: [AppCommand]
    let action: (AppCommand) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: take)
            .onChange(of: model.pendingCommand) { _, _ in take() }
    }

    private func take() {
        guard let c = model.pendingCommand, commands.contains(c) else { return }
        model.pendingCommand = nil
        action(c)
    }
}

extension View {
    /// Carries out the listed menu commands when they are sent to this view.
    func onCommand(_ commands: AppCommand..., perform action: @escaping (AppCommand) -> Void) -> some View {
        modifier(CommandReceiver(commands: commands, action: action))
    }
}

// MARK: - Actions shared by menus and buttons

extension AppModel {
    func exportTransactionsCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ledgerline-export.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let csv = await run({ try $0.exportCsv() }) {
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                    notice = "Exported to \(url.lastPathComponent)."
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func importAppearanceProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import an appearance profile"
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeStore.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ThemeStore.shared.importTheme(from: url) } catch { errorMessage = describe(error) }
    }

    func exportAppearanceProfile() {
        let store = ThemeStore.shared
        let panel = NSSavePanel()
        panel.title = "Export this appearance profile"
        panel.nameFieldStringValue = "\(store.theme.name).\(ThemeStore.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeStore.fileExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(to: url) } catch { errorMessage = describe(error) }
    }
}

// MARK: - The menu bar

struct LedgerlineCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Ledgerline
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { go(.settings) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(model.ledger == nil)
            Button("Appearance…") { openWindow(id: WindowID.appearance) }
        }

        // File
        CommandGroup(replacing: .newItem) {
            FileMenuItems(model: model, showMain: showMain)
        }

        // Edit
        CommandGroup(after: .textEditing) {
            Button("Find Transactions…") { showMain(); model.perform(.searchTransactions) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.ledger == nil)
        }

        // View
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            ViewMenuItems(model: model, showMain: showMain, openAppearance: { openWindow(id: WindowID.appearance) })
        }

        CommandMenu("Go") {
            GoMenuItems(model: model, showMain: showMain)
        }

        CommandMenu("Tools") {
            ToolsMenuItems(model: model, showMain: showMain)
        }

        // Help keeps only its search field, which finds any command above by name.
        CommandGroup(replacing: .help) {}
    }

    private func go(_ page: Page) {
        showMain()
        model.page = page
    }

    /// Brings the main window forward, reopening it if it was closed, so a command always has somewhere to show its result.
    private func showMain() {
        let main = NSApp.windows.first { w in
            !w.isSheet && (w.isVisible || w.isMiniaturized) && w.identifier?.rawValue.hasPrefix(WindowID.main) == true
        }
        if let main {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: WindowID.main)
        }
    }
}

// The items are views, not commands, so they follow the model: checkmarks, the account list
// and what is enabled all update as the app changes.

private struct FileMenuItems: View {
    let model: AppModel
    let showMain: () -> Void

    var body: some View {
        let open = model.ledger != nil
        Menu("New") {
            Button("Account…") { send(.newAccount) }
            Button("Category…") { send(.newCategory) }
            Button("Subcategory…") { send(.newSubcategory) }
            Divider()
            Button("Bill or Income…") { send(.newRecurring) }
            Button("Debt…") { send(.newDebt) }
            Button("Investment Account…") { send(.newInvestment) }
        }
        .disabled(!open)
        Divider()
        Button("Open Database…") { showMain(); model.chooseExistingDatabase() }
            .keyboardShortcut("o", modifiers: .command)
        Button("Create New Database…") { showMain(); model.createNewDatabase() }
        Button("Show Database in Finder") { if let p = model.dbPath { revealInFinder(p) } }
            .disabled(!open)
        Divider()
        Button("Import Bank CSV…") { showMain(); model.page = .import }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!open)
        Button("Export Transactions as CSV…") { model.exportTransactionsCSV() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!open)
        Divider()
        Button("Import Appearance Profile…") { model.importAppearanceProfile() }
        Button("Export Appearance Profile…") { model.exportAppearanceProfile() }
            .disabled(ThemeStore.shared.theme.isSystem)
    }

    private func send(_ c: AppCommand) {
        showMain()
        model.perform(c)
    }
}

private struct ViewMenuItems: View {
    let model: AppModel
    let showMain: () -> Void
    let openAppearance: () -> Void

    var body: some View {
        let open = model.ledger != nil
        Divider()
        Button("Previous Month") { model.month = shiftMonth(month: model.month, n: -1) }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!open)
        Button("Next Month") { model.month = shiftMonth(month: model.month, n: 1) }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!open)
        Button("This Month") { model.month = currentMonth() }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!open || model.month == currentMonth())
        Divider()
        Menu("Account") {
            Toggle("All Accounts", isOn: Binding(get: { model.activeAccount == nil }, set: { _ in model.activeAccount = nil }))
            Divider()
            ForEach(model.accounts) { a in
                Toggle(a.name, isOn: Binding(get: { model.activeAccount == a.id }, set: { _ in model.activeAccount = a.id }))
            }
        }
        .disabled(!open)
        AppearanceMenu(openAppearance: openAppearance)
        Divider()
        Button("Reload") { model.reloadShared() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!open)
        Divider()
    }
}

private struct AppearanceMenu: View {
    let openAppearance: () -> Void

    var body: some View {
        let store = ThemeStore.shared
        Menu("Appearance") {
            if store.isDirty {
                // Switching would throw the edits away, so it waits until they are saved or reverted.
                Text("\(store.theme.name) has unsaved changes")
                Button("Revert Changes") { store.revert() }.disabled(store.baseline == nil)
                Divider()
            }
            ForEach(Theme.builtIns) { profile($0, store) }
            if !store.profiles.isEmpty {
                Divider()
                ForEach(store.profiles) { profile($0, store) }
            }
            Divider()
            Button("Customize…", action: openAppearance)
        }
    }

    private func profile(_ t: Theme, _ store: ThemeStore) -> some View {
        Toggle(t.name, isOn: Binding(get: { store.theme.id == t.id }, set: { _ in store.select(t.id) }))
            .disabled(store.isDirty)
    }
}

private struct GoMenuItems: View {
    let model: AppModel
    let showMain: () -> Void

    var body: some View {
        let open = model.ledger != nil
        ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, p in
            // ⌘1 to ⌘9 for the first nine pages; Settings already has ⌘, in the Ledgerline menu.
            let item = Toggle(p.title, isOn: Binding(get: { model.page == p }, set: { _ in showMain(); model.page = p }))
            if i < 9 {
                item.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            } else {
                item
            }
        }
        .disabled(!open)
        Divider()
        Button("Uncategorized Transactions") { showMain(); model.showTransactions(TxPreset(uncategorizedOnly: true)) }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!open)
        Button("This Month's Transactions") { showMain(); model.showTransactions(TxPreset(month: currentMonth())) }
            .disabled(!open)
    }
}

private struct ToolsMenuItems: View {
    let model: AppModel
    let showMain: () -> Void

    var body: some View {
        let open = model.ledger != nil
        let uncategorized = model.meta?.uncategorized ?? 0
        Group {
            // Categorizing
            Button("Categorization Rules…") { send(.showRules) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Apply Rules to Uncategorized") { Task { await model.applyRules() } }
                .disabled(uncategorized == 0)
            Button("Apply Merchant Memory") { Task { await model.applyMemory() } }
                .disabled(uncategorized == 0)
            Button("AI Sort…") { send(.aiSort) }
            Divider()
            // Finding things in what has been imported
            Button("Find Bills and Income in Transactions…") { send(.findRecurring) }
            Button("Find Debts in Transactions…") { send(.findDebts) }
            Divider()
            Button("AI Category Designer…") { send(.categoryDesigner) }
            Button("Set Cash Balances…") { send(.cashBalances) }
        }
        .disabled(!open)
    }

    private func send(_ c: AppCommand) {
        showMain()
        model.perform(c)
    }
}
