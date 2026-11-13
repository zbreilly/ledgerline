import AppKit
import CryptoKit
import Observation
import SwiftUI

// The appearance engine's data: colors, fonts, layer outlines, panel art and button skins,
// plus the store that saves, imports and exports profiles. Themes are per Mac (like the AI
// settings), never in the database file.

// MARK: - Color math

struct RGBA: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// "#RGB", "#RGBA", "#RRGGBB" or "#RRGGBBAA" (the "#" is optional).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? v >> 8 : v
        r = Double((rgb >> 16) & 0xff) / 255
        g = Double((rgb >> 8) & 0xff) / 255
        b = Double(rgb & 0xff) / 255
        a = s.count == 8 ? Double(v & 0xff) / 255 : 1
    }

    /// "#rrggbb", or "#rrggbbaa" when not fully opaque.
    var hex: String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
        return byte(a) == 255 ? rgb : rgb + String(format: "%02x", byte(a))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// Perceived brightness, 0 (black) to 1 (white).
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var hsva: HSVA {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return HSVA(h: h, s: mx == 0 ? 0 : d / mx, v: mx, a: a)
    }
}

/// Hue, saturation, value and alpha, each 0...1.
struct HSVA: Equatable {
    var h: Double
    var s: Double
    var v: Double
    var a: Double = 1

    var rgba: RGBA {
        let hh = (h - floor(h)) * 6
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch i {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return RGBA(r: r, g: g, b: b, a: a)
    }
}

extension Color {
    /// A theme color string; magenta marks a value that failed to parse.
    init(themeHex: String) {
        self = (RGBA(hex: themeHex) ?? RGBA(r: 1, g: 0, b: 1)).color
    }
}

// MARK: - Theme model

/// An image drawn on a layer or button. `asset` names a file in the theme asset folder.
struct ThemeArt: Codable, Equatable {
    var asset = ""
    /// "fill", "fit", "stretch", "tile" or "frame" (9-slice: corners stay, edges stretch).
    var mode = "fill"
    var opacity = 1.0
    /// Edge size in points for "frame".
    var slice = 12.0
    /// Size multiplier for "fill", "fit" and "tile" (1 = the natural size for that fit).
    var scale = 1.0
    /// Where the image sits in the frame, 0...1 each way: 0 is left or top, 0.5 centered, 1 right or bottom.
    /// For "fill" this chooses which part shows; for "tile" it shifts the pattern.
    var x = 0.5
    var y = 0.5
    /// Draw only the image: no fill color and no outline.
    var replacesFill = false

    static let modes = ["fill", "fit", "stretch", "tile", "frame"]
    /// Modes where the image can be moved and resized inside the frame.
    var canPosition: Bool { mode == "fill" || mode == "fit" || mode == "tile" }

    init(asset: String = "", mode: String = "fill", replacesFill: Bool = false) {
        self.asset = asset; self.mode = mode; self.replacesFill = replacesFill
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asset = try c.decodeIfPresent(String.self, forKey: .asset) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "fill"
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        slice = try c.decodeIfPresent(Double.self, forKey: .slice) ?? 12
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        replacesFill = try c.decodeIfPresent(Bool.self, forKey: .replacesFill) ?? false
    }
}

/// One layer of the interface: its fill, its outline, and optional art.
struct ThemeSurface: Codable, Equatable {
    var fill: String
    var outline: String
    var outlineWidth: Double
    var radius: Double
    /// Blur radius of the glow around the outline (0 = none). This is the neon effect.
    var glow: Double
    var art: ThemeArt?
}

struct ThemeButton: Codable, Equatable {
    var surface: ThemeSurface
    var text: String
    /// Optional images swapped in while the pointer is over the button or pressing it.
    var hoverAsset: String?
    var pressedAsset: String?
}

enum SurfaceKind: String, CaseIterable, Identifiable {
    case window, sidebar, panel, card
    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: "Window"
        case .sidebar: "Sidebar"
        case .panel: "Panels"
        case .card: "Cards"
        }
    }

    var blurb: String {
        switch self {
        case .window: "Every window and sheet: the background, and the outline drawn around the window edge."
        case .sidebar: "The list of pages and accounts on the left."
        case .panel: "The large boxes that group content, such as Net Worth or Categories."
        case .card: "The small boxes: summary numbers, calendar days, and tiles inside panels."
        }
    }
}

struct Theme: Codable, Equatable, Identifiable {
    static let formatName = "ledgerline-theme"

    var format = Theme.formatName
    var version = 1
    var id: String
    var name: String

    var text: String
    var textSecondary: String
    var textTertiary: String
    var accent: String
    var positive: String
    var negative: String
    var warning: String
    var info: String

    /// "system", "rounded", "serif", "mono", or an installed font family name.
    var headingFont = "system"
    var bodyFont = "system"
    var fontScale = 1.0

    var window: ThemeSurface
    var sidebar: ThemeSurface
    var panel: ThemeSurface
    var card: ThemeSurface
    var button: ThemeButton
    var prominentButton: ThemeButton

    /// The standard macOS look. Nothing in the engine draws while this is active.
    var isSystem: Bool { id == "system" }
    var isBuiltIn: Bool { Theme.builtInIDs.contains(id) }

    /// Light or dark system controls, chosen from how bright the window is.
    var isDark: Bool { (RGBA(hex: window.fill)?.luminance ?? 1) < 0.4 }

    static var current: Theme { ThemeStore.shared.theme }

    func surface(_ kind: SurfaceKind) -> ThemeSurface {
        switch kind {
        case .window: window
        case .sidebar: sidebar
        case .panel: panel
        case .card: card
        }
    }

    static func surfacePath(_ kind: SurfaceKind) -> WritableKeyPath<Theme, ThemeSurface> {
        switch kind {
        case .window: \.window
        case .sidebar: \.sidebar
        case .panel: \.panel
        case .card: \.card
        }
    }

    /// Every asset file this theme points at.
    var assetNames: Set<String> {
        var out = Set<String>()
        for s in [window, sidebar, panel, card, button.surface, prominentButton.surface] {
            if let a = s.art?.asset, !a.isEmpty { out.insert(a) }
        }
        for b in [button, prominentButton] {
            for a in [b.hoverAsset, b.pressedAsset] { if let a, !a.isEmpty { out.insert(a) } }
        }
        return out
    }

    /// Every distinct color in the theme, for the picker's swatch row.
    var palette: [String] {
        var seen = Set<String>(), out: [String] = []
        let all = [text, textSecondary, textTertiary, accent, positive, negative, warning, info,
                   window.fill, window.outline, sidebar.fill, sidebar.outline, panel.fill, panel.outline,
                   card.fill, card.outline, button.surface.fill, button.surface.outline, button.text,
                   prominentButton.surface.fill, prominentButton.surface.outline, prominentButton.text]
        for c in all where seen.insert(c.lowercased()).inserted { out.append(c) }
        return out
    }
}

// MARK: - Built-in profiles

extension Theme {
    /// macOS 26 and later round window corners more than earlier systems.
    static var defaultWindowRadius: Double {
        if #available(macOS 26, *) { return 16 }
        return 10
    }

    private struct Line {
        var color: String
        var width = 1.0
        var glow = 0.0
    }

    private static func make(
        id: String, name: String, background: String, text: String, text2: String, text3: String, accent: String,
        positive: String, negative: String, warning: String, info: String,
        window: Line, sidebar: Line, panel: Line, card: Line,
        buttonFill: String, buttonText: String, buttonLine: Line, prominentFill: String, prominentText: String, prominentLine: Line
    ) -> Theme {
        func surface(_ l: Line, radius: Double, fill: String? = nil) -> ThemeSurface {
            ThemeSurface(fill: fill ?? background, outline: l.color, outlineWidth: l.width, radius: radius, glow: l.glow, art: nil)
        }
        return Theme(
            id: id, name: name, text: text, textSecondary: text2, textTertiary: text3, accent: accent,
            positive: positive, negative: negative, warning: warning, info: info,
            window: surface(window, radius: defaultWindowRadius), sidebar: surface(sidebar, radius: 0),
            panel: surface(panel, radius: 10), card: surface(card, radius: 8),
            button: ThemeButton(surface: surface(buttonLine, radius: 6, fill: buttonFill), text: buttonText),
            prominentButton: ThemeButton(surface: surface(prominentLine, radius: 6, fill: prominentFill), text: prominentText))
    }

    /// The System profile carries ordinary light or dark values, so a profile started from it has a sensible base.
    static func system(dark: Bool) -> Theme {
        if dark {
            return make(id: "system", name: "System", background: "#1e1e1e", text: "#ffffff", text2: "#ffffff99", text3: "#ffffff55",
                        accent: "#0a84ff", positive: "#30d158", negative: "#ff453a", warning: "#ff9f0a", info: "#0a84ff",
                        window: Line(color: "#00000000", width: 0), sidebar: Line(color: "#00000000", width: 0),
                        panel: Line(color: "#ffffff1f", width: 0), card: Line(color: "#ffffff1f", width: 0),
                        buttonFill: "#ffffff26", buttonText: "#ffffff", buttonLine: Line(color: "#ffffff26", width: 0),
                        prominentFill: "#0a84ff", prominentText: "#ffffff", prominentLine: Line(color: "#0a84ff", width: 0))
                .with(panelFill: "#2a2a2a", cardFill: "#333333", sidebarFill: "#262626")
        }
        return make(id: "system", name: "System", background: "#ececec", text: "#000000", text2: "#00000099", text3: "#00000055",
                    accent: "#007aff", positive: "#28a745", negative: "#ff3b30", warning: "#f08c00", info: "#007aff",
                    window: Line(color: "#00000000", width: 0), sidebar: Line(color: "#00000000", width: 0),
                    panel: Line(color: "#0000001f", width: 0), card: Line(color: "#0000001f", width: 0),
                    buttonFill: "#ffffff", buttonText: "#000000", buttonLine: Line(color: "#00000033", width: 1),
                    prominentFill: "#007aff", prominentText: "#ffffff", prominentLine: Line(color: "#007aff", width: 0))
            .with(panelFill: "#f6f6f6", cardFill: "#ffffff", sidebarFill: "#e4e4e4")
    }

    private func with(panelFill: String, cardFill: String, sidebarFill: String) -> Theme {
        var t = self
        t.panel.fill = panelFill; t.card.fill = cardFill; t.sidebar.fill = sidebarFill
        return t
    }

    static let builtIns: [Theme] = [
        system(dark: false),
        make(id: "white", name: "All White", background: "#ffffff", text: "#111111", text2: "#555555", text3: "#8a8a8a",
             accent: "#0a60ff", positive: "#12833a", negative: "#c62828", warning: "#b25e00", info: "#0a60ff",
             window: Line(color: "#d9d9d9"), sidebar: Line(color: "#e6e6e6"), panel: Line(color: "#dcdcdc"), card: Line(color: "#e4e4e4"),
             buttonFill: "#ffffff", buttonText: "#111111", buttonLine: Line(color: "#c4c4c4"),
             prominentFill: "#111111", prominentText: "#ffffff", prominentLine: Line(color: "#111111", width: 0)),
        make(id: "black", name: "All Black", background: "#000000", text: "#f2f2f2", text2: "#a6a6a6", text3: "#6e6e6e",
             accent: "#4c9dff", positive: "#3ddc84", negative: "#ff6b6b", warning: "#ffb347", info: "#4c9dff",
             window: Line(color: "#2c2c2c"), sidebar: Line(color: "#1f1f1f"), panel: Line(color: "#2a2a2a"), card: Line(color: "#242424"),
             buttonFill: "#000000", buttonText: "#f2f2f2", buttonLine: Line(color: "#4a4a4a"),
             prominentFill: "#f2f2f2", prominentText: "#000000", prominentLine: Line(color: "#f2f2f2", width: 0)),
        make(id: "contrast-dark", name: "High Contrast Dark", background: "#000000", text: "#ffffff", text2: "#e6e6e6", text3: "#bdbdbd",
             accent: "#ffe600", positive: "#00ff7f", negative: "#ff5c5c", warning: "#ffb000", info: "#5cd6ff",
             window: Line(color: "#ffffff", width: 2), sidebar: Line(color: "#ffffff", width: 1), panel: Line(color: "#ffffff", width: 2), card: Line(color: "#ffffff", width: 1.5),
             buttonFill: "#000000", buttonText: "#ffffff", buttonLine: Line(color: "#ffffff", width: 2),
             prominentFill: "#ffe600", prominentText: "#000000", prominentLine: Line(color: "#ffffff", width: 2)),
        make(id: "contrast-light", name: "High Contrast Light", background: "#ffffff", text: "#000000", text2: "#1f1f1f", text3: "#444444",
             accent: "#0033cc", positive: "#005c1e", negative: "#a80000", warning: "#7a3d00", info: "#0033cc",
             window: Line(color: "#000000", width: 2), sidebar: Line(color: "#000000", width: 1), panel: Line(color: "#000000", width: 2), card: Line(color: "#000000", width: 1.5),
             buttonFill: "#ffffff", buttonText: "#000000", buttonLine: Line(color: "#000000", width: 2),
             prominentFill: "#000000", prominentText: "#ffffff", prominentLine: Line(color: "#000000", width: 2)),
        make(id: "neon-black", name: "Black with Neon", background: "#000000", text: "#f4f4f4", text2: "#a9b4c0", text3: "#6c7682",
             accent: "#00e5ff", positive: "#39ff14", negative: "#ff3864", warning: "#ffd300", info: "#00e5ff",
             window: Line(color: "#00e5ff", width: 2, glow: 10), sidebar: Line(color: "#b026ff", width: 1, glow: 6),
             panel: Line(color: "#ff2bd6", width: 1.5, glow: 7), card: Line(color: "#39ff14", width: 1, glow: 5),
             buttonFill: "#000000", buttonText: "#00e5ff", buttonLine: Line(color: "#00e5ff", width: 1.5, glow: 5),
             prominentFill: "#00e5ff", prominentText: "#000000", prominentLine: Line(color: "#00e5ff", width: 1.5, glow: 8)),
        make(id: "neon-white", name: "White with Neon", background: "#ffffff", text: "#141414", text2: "#4d4d5a", text3: "#85859a",
             accent: "#d600c4", positive: "#00a843", negative: "#ff1f5a", warning: "#e07a00", info: "#0091ff",
             window: Line(color: "#ff00d4", width: 2, glow: 10), sidebar: Line(color: "#7a00ff", width: 1, glow: 6),
             panel: Line(color: "#00b7ff", width: 1.5, glow: 7), card: Line(color: "#ff00d4", width: 1, glow: 5),
             buttonFill: "#ffffff", buttonText: "#d600c4", buttonLine: Line(color: "#ff00d4", width: 1.5, glow: 5),
             prominentFill: "#ff00d4", prominentText: "#ffffff", prominentLine: Line(color: "#ff00d4", width: 1.5, glow: 8)),
    ]

    static let builtInIDs = Set(builtIns.map(\.id))
}

// MARK: - Reading theme files

struct ThemeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Theme {
    /// Reads a theme leniently: missing values fall back to the light base, and every value is checked.
    static func decode(object: [String: Any]) throws -> Theme {
        guard object["format"] as? String == formatName else {
            throw ThemeError("This isn't a Ledgerline theme file.")
        }
        guard let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(system(dark: false))) as? [String: Any] else {
            throw ThemeError("Could not read the theme.")
        }
        var merged = deepMerge(base, object)
        merged.removeValue(forKey: "assets")
        do {
            return try JSONDecoder().decode(Theme.self, from: JSONSerialization.data(withJSONObject: merged)).sanitized()
        } catch {
            throw ThemeError("The theme file has values Ledgerline can't read.")
        }
    }

    static func decode(_ data: Data) throws -> Theme {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThemeError("This isn't a Ledgerline theme file.")
        }
        return try decode(object: object)
    }

    private static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let a = out[k] as? [String: Any], let b = v as? [String: Any] { out[k] = deepMerge(a, b) } else { out[k] = v }
        }
        return out
    }

    static func isAssetName(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "png" || parts[1] == "svg", parts[0].count == 32 else { return false }
        return parts[0].allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Clamps numbers, normalizes colors and drops anything that isn't a known value.
    func sanitized() -> Theme {
        let base = Theme.system(dark: false)
        var t = self
        func color(_ s: String, _ fallback: String) -> String { RGBA(hex: s)?.hex ?? fallback }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : fallback }
        func font(_ s: String) -> String {
            let f = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return f.isEmpty || f.count > 100 ? "system" : f
        }
        func asset(_ s: String?) -> String? { s.flatMap { Theme.isAssetName($0) ? $0 : nil } }
        func surface(_ s: ThemeSurface, _ b: ThemeSurface) -> ThemeSurface {
            var o = s
            o.fill = color(s.fill, b.fill)
            o.outline = color(s.outline, b.outline)
            o.outlineWidth = clamp(s.outlineWidth, 0, 12, b.outlineWidth)
            o.radius = clamp(s.radius, 0, 60, b.radius)
            o.glow = clamp(s.glow, 0, 40, 0)
            if var a = s.art, Theme.isAssetName(a.asset) {
                if !ThemeArt.modes.contains(a.mode) { a.mode = "fill" }
                a.opacity = clamp(a.opacity, 0, 1, 1)
                a.slice = clamp(a.slice, 1, 200, 12)
                a.scale = clamp(a.scale, 0.05, 8, 1)
                a.x = clamp(a.x, 0, 1, 0.5)
                a.y = clamp(a.y, 0, 1, 0.5)
                o.art = a
            } else {
                o.art = nil
            }
            return o
        }
        func button(_ s: ThemeButton, _ b: ThemeButton) -> ThemeButton {
            ThemeButton(surface: surface(s.surface, b.surface), text: color(s.text, b.text),
                        hoverAsset: asset(s.hoverAsset), pressedAsset: asset(s.pressedAsset))
        }
        t.format = Theme.formatName
        t.version = 1
        let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.name = name.isEmpty ? "Untitled" : String(name.prefix(60))
        if t.id.isEmpty || t.id.count > 64 || !t.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) {
            t.id = UUID().uuidString.lowercased()
        }
        t.text = color(t.text, base.text)
        t.textSecondary = color(t.textSecondary, base.textSecondary)
        t.textTertiary = color(t.textTertiary, base.textTertiary)
        t.accent = color(t.accent, base.accent)
        t.positive = color(t.positive, base.positive)
        t.negative = color(t.negative, base.negative)
        t.warning = color(t.warning, base.warning)
        t.info = color(t.info, base.info)
        t.headingFont = font(t.headingFont)
        t.bodyFont = font(t.bodyFont)
        t.fontScale = clamp(t.fontScale, 0.7, 1.6, 1)
        t.window = surface(t.window, base.window)
        t.sidebar = surface(t.sidebar, base.sidebar)
        t.panel = surface(t.panel, base.panel)
        t.card = surface(t.card, base.card)
        t.button = button(t.button, base.button)
        t.prominentButton = button(t.prominentButton, base.prominentButton)
        return t
    }
}

// MARK: - Store

/// Holds the theme being shown, the saved profiles, and the art files.
/// Views read `Theme.current`; Observation re-renders them when it changes.
@Observable
final class ThemeStore: @unchecked Sendable {
    static let shared = ThemeStore()

    /// The theme on screen. Edits apply at once; `save()` writes them to the profile.
    var theme: Theme
    /// Profiles the user saved (built-ins are in `Theme.builtIns`).
    private(set) var profiles: [Theme] = []
    /// The saved or built-in version of the profile being edited (nil = never saved).
    private(set) var baseline: Theme?
    /// Bumped when art files change, so views showing them redraw.
    private(set) var assetRevision = 0

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var pendingWrite: DispatchWorkItem?
    @ObservationIgnored let directory: URL

    static let maxAssetBytes = 12 * 1024 * 1024
    static let maxImportBytes = 96 * 1024 * 1024
    static let fileExtension = "ledgerlinetheme"

    private var profilesDir: URL { directory.appendingPathComponent("Profiles", isDirectory: true) }
    private var assetsDir: URL { directory.appendingPathComponent("Assets", isDirectory: true) }
    private var activeFile: URL { directory.appendingPathComponent("active.json") }

    private init() {
        if let env = ProcessInfo.processInfo.environment["LEDGERLINE_THEMES"], !env.isEmpty {
            directory = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            directory = base.appendingPathComponent("Ledgerline/Themes", isDirectory: true)
        }
        theme = Theme.system(dark: Self.systemIsDark)
        baseline = theme
        loadProfiles()
        if let data = try? Data(contentsOf: activeFile), let saved = try? Theme.decode(data), !saved.isSystem {
            theme = saved
            baseline = profile(saved.id)
        }
        removeUnusedAssets()
    }

    private static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    var allProfiles: [Theme] { Theme.builtIns + profiles }

    func profile(_ id: String) -> Theme? {
        if id == "system" { return Theme.system(dark: Self.systemIsDark) }
        return allProfiles.first { $0.id == id }
    }

    func isSaved(_ id: String) -> Bool { profiles.contains { $0.id == id } }

    /// True when the theme on screen differs from its saved profile.
    var isDirty: Bool { !theme.isSystem && theme != baseline }

    // MARK: Editing

    /// Call after `theme` changes. A changed built-in becomes a new unsaved profile; the result is kept for the next launch.
    func themeChanged() {
        if theme.isBuiltIn, let b = baseline, theme != b, theme.id == b.id {
            theme.id = UUID().uuidString.lowercased()
            theme.name = uniqueName(b.isSystem ? "My Theme" : "\(b.name) Custom", except: theme.id)
        }
        pendingWrite?.cancel()
        let snapshot = theme
        let work = DispatchWorkItem { [weak self] in self?.writeActive(snapshot) }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func writeActive(_ t: Theme) {
        if t.isSystem {
            try? FileManager.default.removeItem(at: activeFile)
        } else {
            try? write(t, to: activeFile)
        }
    }

    func select(_ id: String) {
        guard let p = profile(id) else { return }
        theme = p
        baseline = p
    }

    func revert() {
        if let baseline { theme = baseline }
    }

    /// Overwrites the saved profile with what's on screen.
    func save() throws {
        guard let i = profiles.firstIndex(where: { $0.id == theme.id }) else {
            throw ThemeError("Give this profile a name first.")
        }
        try write(theme, to: profileFile(theme.id))
        profiles[i] = theme
        baseline = theme
    }

    /// Saves what's on screen as a new profile and switches to it.
    func saveAs(_ name: String) throws {
        var t = theme
        if t.isBuiltIn || isSaved(t.id) { t.id = UUID().uuidString.lowercased() }
        t.name = uniqueName(name, except: t.id)
        t = t.sanitized()
        try write(t, to: profileFile(t.id))
        profiles.append(t)
        sortProfiles()
        theme = t
        baseline = t
    }

    func rename(_ name: String) throws {
        theme.name = uniqueName(name, except: theme.id)
        guard let i = profiles.firstIndex(where: { $0.id == theme.id }) else { return }
        var saved = profiles[i]
        saved.name = theme.name
        try write(saved, to: profileFile(saved.id))
        profiles[i] = saved
        if baseline?.id == saved.id { baseline?.name = saved.name }
        sortProfiles()
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: profileFile(id))
        profiles.removeAll { $0.id == id }
        if theme.id == id { select("system") }
    }

    private func uniqueName(_ name: String, except id: String) -> String {
        let base = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(56))
        let taken = Set(allProfiles.filter { $0.id != id }.map { $0.name.lowercased() })
        var candidate = base.isEmpty ? "Untitled" : base
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    private func sortProfiles() {
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Files

    private func profileFile(_ id: String) -> URL { profilesDir.appendingPathComponent("\(id).json") }

    private func write(_ t: Theme, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(t).write(to: url, options: .atomic)
    }

    private func loadProfiles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil)) ?? []
        var seen = Theme.builtInIDs
        profiles = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let t = try? Theme.decode(data) else { return nil }
            // The file name is the id; a file that disagrees was copied in by hand.
            guard t.id == url.deletingPathExtension().lastPathComponent, seen.insert(t.id).inserted else { return nil }
            return t
        }
        sortProfiles()
    }

    /// Art files nothing points at any more (checked once, at launch).
    private func removeUnusedAssets() {
        let used = allProfiles.reduce(into: theme.assetNames) { $0.formUnion($1.assetNames) }
        let files = (try? FileManager.default.contentsOfDirectory(at: assetsDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where Theme.isAssetName(f.lastPathComponent) && !used.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: Art

    /// Copies a PNG or SVG into the asset folder and returns its name there.
    func addAsset(from url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxAssetBytes else { throw ThemeError("That image is larger than 12 MB.") }
        return try addAsset(Data(contentsOf: url))
    }

    func addAsset(_ data: Data) throws -> String {
        guard data.count <= Self.maxAssetBytes else { throw ThemeError("That image is larger than 12 MB.") }
        guard let ext = Self.imageKind(data) else { throw ThemeError("Only PNG and SVG images can be used.") }
        guard Self.loadImage(data, ext: ext) != nil else { throw ThemeError("That image couldn't be read.") }
        let hash = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let name = "\(hash).\(ext)"
        let dest = assetsDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
        }
        assetRevision += 1
        return name
    }

    /// Decides the type from the bytes, not the file name.
    private static func imageKind(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "png" }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        return head.contains("<svg") ? "svg" : nil
    }

    func image(_ name: String?) -> NSImage? {
        _ = assetRevision
        guard let name, Theme.isAssetName(name) else { return nil }
        if let cached = images[name] { return cached }
        guard let data = try? Data(contentsOf: assetsDir.appendingPathComponent(name)),
              let img = Self.loadImage(data, ext: (name as NSString).pathExtension) else { return nil }
        images[name] = img
        return img
    }

    /// PNGs load as they are. SVGs are drawn once into a bitmap so every fit mode treats them the same way.
    private static func loadImage(_ data: Data, ext: String) -> NSImage? {
        guard let src = NSImage(data: data), src.isValid else { return nil }
        guard ext == "svg" else { return src.size.width > 0 && src.size.height > 0 ? src : nil }
        var size = src.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 256, height: 256) }
        let longest = max(size.width, size.height)
        let k = min(max(1536 / longest, 1), 6) * min(1, 4096 / longest)
        let w = max(1, Int(size.width * k)), h = max(1, Int(size.height * k))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Set the point size before making the context, so drawing in points fills every pixel.
        rep.size = size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        src.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    // MARK: Import and export

    /// One self-contained file: the theme plus its art, base64-encoded.
    func export(to url: URL) throws {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any] else {
            throw ThemeError("Could not write the theme.")
        }
        var assets: [String: String] = [:]
        for name in theme.assetNames {
            if let data = try? Data(contentsOf: assetsDir.appendingPathComponent(name)) { assets[name] = data.base64EncodedString() }
        }
        object["assets"] = assets
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    /// Reads a theme file from anywhere. Nothing in it is trusted: values are checked, art is
    /// re-identified from its bytes and stored under a name this app chooses, and it gets a new id.
    @discardableResult
    func importTheme(from url: URL) throws -> Theme {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxImportBytes else { throw ThemeError("That theme file is too large.") }
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ThemeError("This isn't a Ledgerline theme file.")
        }
        guard object["format"] as? String == Theme.formatName else { throw ThemeError("This isn't a Ledgerline theme file.") }

        var renamed: [String: String] = [:]
        if let assets = object["assets"] as? [String: Any] {
            guard assets.count <= 32 else { throw ThemeError("That theme has too many images.") }
            for (name, value) in assets {
                guard let b64 = value as? String, let data = Data(base64Encoded: b64) else { continue }
                if let stored = try? addAsset(data) { renamed[name] = stored }
            }
        }
        var raw = object
        raw.removeValue(forKey: "assets")
        raw["id"] = UUID().uuidString.lowercased()
        var t = try Theme.decode(object: Self.remapAssets(raw, renamed))
        t.name = uniqueName(t.name, except: t.id)
        try write(t, to: profileFile(t.id))
        profiles.append(t)
        sortProfiles()
        theme = t
        baseline = t
        return t
    }

    /// Points every art reference at the stored copy; references to art the file didn't include are dropped.
    private static func remapAssets(_ value: [String: Any], _ renamed: [String: String]) -> [String: Any] {
        var out = value
        for (k, v) in value {
            if let d = v as? [String: Any] {
                if k == "art" {
                    if let a = d["asset"] as? String, let stored = renamed[a] {
                        var art = d
                        art["asset"] = stored
                        out[k] = art
                    } else {
                        out.removeValue(forKey: k)
                    }
                } else {
                    out[k] = remapAssets(d, renamed)
                }
            } else if k == "hoverAsset" || k == "pressedAsset" {
                if let a = v as? String, let stored = renamed[a] { out[k] = stored } else { out.removeValue(forKey: k) }
            }
        }
        return out
    }
}

// MARK: - What views read

/// Text colors. Under the System profile these are the ordinary macOS styles.
enum Ink {
    static var primary: AnyShapeStyle {
        let t = Theme.current
        return t.isSystem ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(themeHex: t.text))
    }

    static var secondary: AnyShapeStyle {
        let t = Theme.current
        return t.isSystem ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(themeHex: t.textSecondary))
    }

    static var tertiary: AnyShapeStyle {
        let t = Theme.current
        return t.isSystem ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color(themeHex: t.textTertiary))
    }
}

extension Color {
    private static func themed(_ system: Color, _ path: KeyPath<Theme, String>) -> Color {
        let t = Theme.current
        return t.isSystem ? system : Color(themeHex: t[keyPath: path])
    }

    static var themeText: Color { themed(.primary, \.text) }
    static var themeSecondary: Color { themed(.secondary, \.textSecondary) }
    static var themeAccent: Color { themed(.accentColor, \.accent) }
    /// Money in, paid, on track.
    static var positive: Color { themed(.green, \.positive) }
    /// Money owed, over budget, errors.
    static var negative: Color { themed(.red, \.negative) }
    static var warning: Color { themed(.orange, \.warning) }
    static var info: Color { themed(.blue, \.info) }
}

extension Font {
    /// The theme's font for a text style. Under the System profile this is the plain system style.
    static func app(_ style: Font.TextStyle) -> Font {
        let t = Theme.current
        if t.isSystem { return .system(style) }
        let heading: Bool, base: CGFloat
        switch style {
        case .largeTitle: (heading, base) = (true, 26)
        case .title: (heading, base) = (true, 22)
        case .title2: (heading, base) = (true, 17)
        case .title3: (heading, base) = (true, 15)
        case .headline: (heading, base) = (true, 13)
        case .subheadline: (heading, base) = (false, 11)
        case .callout: (heading, base) = (false, 12)
        case .footnote, .caption, .caption2: (heading, base) = (false, 10)
        default: (heading, base) = (false, 13)
        }
        let size = base * t.fontScale
        let weight: Font.Weight = style == .headline ? .bold : .regular
        switch heading ? t.headingFont : t.bodyFont {
        case "system", "": return .system(size: size, weight: weight)
        case "rounded": return .system(size: size, weight: weight, design: .rounded)
        case "serif": return .system(size: size, weight: weight, design: .serif)
        case "mono": return .system(size: size, weight: weight, design: .monospaced)
        case let family: return .custom(family, fixedSize: size).weight(weight)
        }
    }
}
