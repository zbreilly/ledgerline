import AppKit
import SwiftUI

// MARK: - Identifiable conformances for core records

extension Transaction: Identifiable {}
extension Account: Identifiable {}
extension Category: Identifiable {}
extension Subcategory: Identifiable {}
extension Rule: Identifiable {}
extension ImportBatch: Identifiable {}
extension BreakdownCategory: Identifiable {}
extension BreakdownSub: Identifiable {}
extension PlanCategory: Identifiable {}
extension PlanSub: Identifiable {}
extension Suggestion: Identifiable {}
extension BudgetLine: Identifiable {}
extension MonthFlow: Identifiable { public var id: String { ym } }
extension MerchantTotal: Identifiable { public var id: String { name } }
extension ProposedCategory: Identifiable { public var id: String { name } }
extension AccountReport: Identifiable { public var id: String { account.id } }
extension PreviewRow: Identifiable { public var id: UInt32 { line } }
extension NetPoint: Identifiable { public var id: String { ym } }

extension String {
    /// Bank exports pad descriptions with runs of spaces; collapse them for display.
    var squished: String {
        split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}

extension Transaction {
    var displayName: String { (merchant.isEmpty ? description : merchant).squished }
    var accountSort: String { accountName ?? "" }
    var categorySort: String { categoryName ?? "" }
    var subcategorySort: String { subcategoryName ?? "" }
}

// MARK: - Errors

func describe(_ error: Error) -> String {
    if case let LedgerError.Message(msg) = error { return msg }
    return error.localizedDescription
}

// MARK: - Money and dates

enum Money {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// "−$1,234.56" for money out; "+$12.00" when `sign` and positive.
    static func format(_ cents: Int64, sign: Bool = false, compact: Bool = false) -> String {
        let absC = abs(cents)
        var s: String
        if compact && absC >= 100_000 {
            let k = Double(absC) / 100_000
            s = "$" + (absC >= 10_000_000 ? String(format: "%.0fk", k) : String(format: "%.1fk", k))
        } else {
            s = formatter.string(from: NSNumber(value: Double(absC) / 100)) ?? "$0.00"
        }
        if sign && cents > 0 { return "+" + s }
        return (cents < 0 ? "−" : "") + s
    }

    /// Plain editable form: "-12.34".
    static func plain(_ cents: Int64) -> String {
        String(format: "%.2f", Double(cents) / 100)
    }
}

enum Dates {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) }
    static func string(_ d: Date) -> String { iso.string(from: d) }

    static func medium(_ s: String) -> String {
        guard let d = date(s) else { return s }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func short(_ s: String) -> String {
        guard let d = date(s) else { return s }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "2026-10" -> "October 2026"
    static func monthTitle(_ ym: String) -> String {
        guard let d = date(ym + "-01") else { return ym }
        return d.formatted(.dateTime.month(.wide).year())
    }
}

// MARK: - Colors

extension Color {
    init(hex: String?) {
        var s = (hex ?? "").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .accentColor
            return
        }
        self = Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02x%02x%02x", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }

    static var moneyIn: Color { .positive }
    static var moneyOut: Color { .themeText }
}

// MARK: - Small shared views

struct MonthStepper: View {
    @Binding var month: String

    var body: some View {
        HStack(spacing: 4) {
            Button { month = shiftMonth(month: month, n: -1) } label: { Image(systemName: "chevron.left") }
                .help("Previous month")
            Text(Dates.monthTitle(month))
                .font(Font.app(.headline))
                .frame(minWidth: 130)
            Button { month = shiftMonth(month: month, n: 1) } label: { Image(systemName: "chevron.right") }
                .help("Next month")
            if month != currentMonth() {
                Button("This month") { month = currentMonth() }
            }
        }
        .buttonStyle(.borderless)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    var detail: String? = nil
    var tint: Color = Color.themeText

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Font.app(.subheadline)).foregroundStyle(Ink.secondary)
            Text(value).font(Font.app(.title2).weight(.semibold).monospacedDigit()).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(Font.app(.caption)).foregroundStyle(Ink.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .surface(.card, radius: 10)
    }
}

struct Panel<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(Font.app(.headline))
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surface(.panel, radius: 10)
    }
}

struct CategoryBadge: View {
    let name: String?
    let color: String?
    let icon: String?
    var sub: String? = nil

    var body: some View {
        if let name {
            HStack(spacing: 4) {
                Circle().fill(Color(hex: color)).frame(width: 8, height: 8)
                Text(iconPrefix + name + (sub.map { " › \($0)" } ?? "")).lineLimit(1)
            }
        } else {
            Text("Uncategorized").foregroundStyle(Color.warning)
        }
    }

    private var iconPrefix: String {
        guard let icon, !icon.isEmpty, icon != "folder" else { return "" }
        return icon + " "
    }
}

struct AmountText: View {
    let cents: Int64
    var body: some View {
        Text(Money.format(cents, sign: true))
            .monospacedDigit()
            .foregroundStyle(cents > 0 ? Color.moneyIn : Color.moneyOut)
    }
}

/// Category + subcategory picker backed by the shared category list.
struct CategoryPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var categoryId: String?
    @Binding var subcategoryId: String?
    var allowNone = true
    @State private var addingSub = false

    var body: some View {
        Picker("Category", selection: $categoryId) {
            if allowNone { Text("Uncategorized").tag(String?.none) }
            ForEach(model.categories) { c in
                Text("\(c.icon == "folder" ? "" : c.icon + " ")\(c.name)").tag(Optional(c.id))
            }
        }
        .onChange(of: categoryId) { _, _ in
            if let s = subcategoryId, !(selectedCategory?.subcategories.contains { $0.id == s } ?? false) {
                subcategoryId = nil
            }
        }
        if let cat = selectedCategory {
            HStack {
                Picker("Subcategory", selection: $subcategoryId) {
                    Text("None").tag(String?.none)
                    ForEach(cat.subcategories) { s in Text(s.name).tag(Optional(s.id)) }
                }
                Button { addingSub = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New subcategory in \(cat.name)")
            }
            .sheet(isPresented: $addingSub) {
                NameSheet(title: "New subcategory in \(cat.name)", initial: "") { name in
                    let cid = cat.id
                    Task {
                        if let id = await model.write({ try $0.createSubcategory(categoryId: cid, name: name) }) {
                            subcategoryId = id
                        }
                    }
                }
            }
        }
    }

    private var selectedCategory: Category? {
        model.categories.first { $0.id == categoryId }
    }
}

/// Text field that edits cents as a dollar string.
struct MoneyField: View {
    let title: String
    @Binding var cents: Int64?

    @State private var text = ""

    var body: some View {
        TextField(title, text: $text)
            .monospacedDigit()
            .onAppear { text = cents.map(Money.plain) ?? "" }
            .onChange(of: text) { _, new in
                cents = new.trimmingCharacters(in: .whitespaces).isEmpty ? nil : parseMoney(text: new)
            }
    }
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
