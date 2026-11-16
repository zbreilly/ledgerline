import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Appearance window: pick a profile, change colors, fonts, layers, art and buttons, and
/// save, import or export the result. Edits show at once in every window.
struct AppearanceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var host = HostWindow()
    @State private var tab = EditorTab.layers
    @State private var layer = SurfaceKind.window
    @State private var prominent = false
    @State private var naming: Naming?
    @State private var pendingProfile: String?
    @State private var confirmDelete = false

    enum EditorTab: String, CaseIterable, Identifiable {
        case layers = "Layers", colors = "Colors", fonts = "Fonts", buttons = "Buttons"
        var id: String { rawValue }
    }

    enum Naming: String, Identifiable {
        case saveAs, rename
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var store = ThemeStore.shared
        VStack(spacing: 0) {
            profileBar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Picker("Section", selection: $tab) {
                        ForEach(EditorTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    Form {
                        if store.theme.isSystem {
                            Section {
                                Text("System is the standard macOS look. Change anything here to start a profile of your own, or pick one of the built-in profiles above.")
                                    .foregroundStyle(Ink.secondary)
                            }
                        }
                        switch tab {
                        case .layers: layersTab()
                        case .colors: colorsTab()
                        case .fonts: fontsTab()
                        case .buttons: buttonsTab()
                        }
                    }
                    .formStyle(.grouped)
                }
                .frame(minWidth: 440)
                Divider()
                ThemePreview().frame(width: 300)
            }
            Divider()
            closeBar
        }
        .background(WindowBackdrop())
        .background(HostWindowReader(host: host))
        .frame(minWidth: 760, minHeight: 560)
        .sheet(item: $naming) { kind in
            NameSheet(title: kind == .saveAs ? "Save profile as" : "Rename profile", initial: store.theme.isBuiltIn ? "My Theme" : store.theme.name) { name in
                attempt { kind == .saveAs ? try store.saveAs(name) : try store.rename(name) }
            }
        }
        .confirmationDialog("Discard the changes to \(store.theme.name)?", isPresented: Binding(get: { pendingProfile != nil }, set: { if !$0 { pendingProfile = nil } })) {
            Button("Discard Changes", role: .destructive) {
                if let id = pendingProfile { store.select(id) }
                pendingProfile = nil
            }
        } message: {
            Text("This profile has changes that haven't been saved.")
        }
        .confirmationDialog("Delete the profile \(store.theme.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(store.theme.id) }
        } message: {
            Text("This can't be undone. Export it first if you might want it back.")
        }
    }

    // MARK: Profiles

    private var profileBar: some View {
        let store = ThemeStore.shared
        let saved = store.isSaved(store.theme.id)
        return HStack(spacing: 8) {
            Picker("Profile", selection: Binding(get: { store.theme.id }, set: { choose($0) })) {
                Section("Built in") {
                    ForEach(Theme.builtIns) { Text($0.name).tag($0.id) }
                }
                if !store.profiles.isEmpty {
                    Section("Saved") {
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }
                }
                if !saved && !store.theme.isBuiltIn {
                    Section("Not saved yet") { Text(store.theme.name).tag(store.theme.id) }
                }
            }
            .frame(maxWidth: 300)
            if store.isDirty {
                Text(saved ? "Edited" : "Not saved").font(Font.app(.caption)).foregroundStyle(Color.warning)
            }
            Spacer()
            Button("Revert") { store.revert() }
                .disabled(!store.isDirty || store.baseline == nil)
                .help("Throw away the changes since this profile was last saved")
            Button("Save") {
                if saved { attempt { try store.save() } } else { naming = .saveAs }
            }
            .disabled(!store.isDirty)
            Button("Save As…") { naming = .saveAs }
            Menu {
                Button("Rename…") { naming = .rename }.disabled(!saved)
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(!saved)
                Divider()
                Button("Import Profile…") { model.importAppearanceProfile() }
                Button("Export Profile…") { model.exportAppearanceProfile() }.disabled(store.theme.isSystem)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Rename, delete, import or export")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The way out. Closing never loses anything: edits are already on screen and are kept.
    private var closeBar: some View {
        let store = ThemeStore.shared
        return HStack(spacing: 12) {
            Text(store.theme.isSystem ? "Nothing here changes until you edit something or pick a profile."
                 : store.isDirty ? "Your changes are in use and will still be here next time. Save to keep them in the profile, or Revert to undo them."
                 : "This profile is in use. Changes show right away.")
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                .lineLimit(2)
            Spacer()
            Button("Done", action: close)
                .buttonStyle(.themedProminent)
                .keyboardShortcut(.cancelAction)
                .help("Close this window (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Closes the window the same way its red close button does.
    private func close() {
        if let window = host.window ?? NSApp.keyWindow {
            window.performClose(nil)
        } else {
            dismissWindow(id: WindowID.appearance)
        }
    }

    private func choose(_ id: String) {
        let store = ThemeStore.shared
        guard id != store.theme.id else { return }
        if store.isDirty { pendingProfile = id } else { store.select(id) }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { model.errorMessage = describe(error) }
    }

    // MARK: Tabs

    @ViewBuilder private func layersTab() -> some View {
        @Bindable var store = ThemeStore.shared
        Section {
            Picker("Layer", selection: $layer) {
                ForEach(SurfaceKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(layer.blurb).font(Font.app(.caption)).foregroundStyle(Ink.secondary)
        }
        SurfaceEditor(surface: Binding(get: { store.theme[keyPath: Theme.surfacePath(layer)] },
                                       set: { store.theme[keyPath: Theme.surfacePath(layer)] = $0 }),
                      radiusLabel: layer == .window ? "Outline corner radius" : "Corner radius",
                      radiusHelp: layer == .window ? "Match this to the window's own rounded corners so the outline follows the edge." : nil)
            .id(layer)
    }

    @ViewBuilder private func colorsTab() -> some View {
        @Bindable var store = ThemeStore.shared
        Section("Text") {
            ThemeColorRow(label: "Main text", hex: $store.theme.text)
            ThemeColorRow(label: "Secondary text", hex: $store.theme.textSecondary)
            ThemeColorRow(label: "Faint text", hex: $store.theme.textTertiary)
        }
        Section("Accent") {
            ThemeColorRow(label: "Accent", hex: $store.theme.accent)
            Text("Used for selected controls, links, progress bars and the current day.")
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
        }
        Section("Meaning") {
            ThemeColorRow(label: "Money in, on track", hex: $store.theme.positive)
            ThemeColorRow(label: "Owed, over budget", hex: $store.theme.negative)
            ThemeColorRow(label: "Needs attention", hex: $store.theme.warning)
            ThemeColorRow(label: "Notes and hints", hex: $store.theme.info)
        }
        Section {
            Text("Fills and outlines for windows, panels and cards are on the Layers tab. Button colors are on the Buttons tab.")
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
        }
    }

    @ViewBuilder private func fontsTab() -> some View {
        @Bindable var store = ThemeStore.shared
        Section("Typefaces") {
            FontPicker(label: "Headings", family: $store.theme.headingFont)
            FontPicker(label: "Body text", family: $store.theme.bodyFont)
            SliderRow(label: "Size", value: $store.theme.fontScale, range: 0.8...1.4, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
        }
        Section("Sample") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Net worth").font(Font.app(.title).weight(.semibold))
                Text("Where the money went").font(Font.app(.headline))
                Text("Groceries came in under budget this month.").font(Font.app(.body))
                Text("$1,234.56").font(Font.app(.title3).weight(.semibold).monospacedDigit())
                Text("Last activity Oct 23, 2026").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            }
        }
        Section {
            Text("Menus, table headers and the text inside pop-up controls are drawn by macOS and keep the system font.")
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
        }
    }

    @ViewBuilder private func buttonsTab() -> some View {
        @Bindable var store = ThemeStore.shared
        let skin = prominent ? $store.theme.prominentButton : $store.theme.button
        Section {
            Picker("Button", selection: $prominent) {
                Text("Standard").tag(false)
                Text("Main action").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(prominent ? "The button that confirms a sheet (Save, Import) and other primary actions." : "Every other push button.")
                .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
        }
        Section("Label") {
            ThemeColorRow(label: "Text", hex: skin.text)
        }
        SurfaceEditor(surface: skin.surface, artTitle: "Custom button image", artMode: "frame", artReplaces: true)
            .id(prominent)
        if skin.wrappedValue.surface.art != nil {
            Section("Images for other states") {
                AssetRow(label: "Pointer over", asset: skin.hoverAsset)
                AssetRow(label: "Pressed", asset: skin.pressedAsset)
                Text("Optional. They use the same fit as the main image. Without them the button lightens or darkens instead.")
                    .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
            }
        }
    }
}

/// Holds a view placed in the window, so a button can ask which window it is in at the moment it's pressed.
final class HostWindow {
    weak var anchor: NSView?
    var window: NSWindow? { anchor?.window }
}

struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        host.anchor = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        host.anchor = nsView
    }
}

// MARK: - Editors

/// Fill, outline and art for one layer or button.
struct SurfaceEditor: View {
    @Binding var surface: ThemeSurface
    var radiusLabel = "Corner radius"
    var radiusHelp: String? = nil
    var artTitle = "Art"
    var artMode = "fill"
    var artReplaces = false

    var body: some View {
        Section("Fill") {
            ThemeColorRow(label: "Color", hex: $surface.fill)
        }
        Section("Outline") {
            ThemeColorRow(label: "Color", hex: $surface.outline)
            SliderRow(label: "Width", value: $surface.outlineWidth, range: 0...8, step: 0.5) { String(format: "%g pt", $0) }
            SliderRow(label: "Glow", value: $surface.glow, range: 0...30, step: 1) { $0 == 0 ? "Off" : String(format: "%g", $0) }
            SliderRow(label: radiusLabel, value: $surface.radius, range: 0...40, step: 1) { String(format: "%g", $0) }
            if let radiusHelp { Text(radiusHelp).font(Font.app(.caption)).foregroundStyle(Ink.secondary) }
        }
        Section(artTitle) {
            ArtEditor(art: $surface.art, surface: surface, defaultMode: artMode, defaultReplaces: artReplaces)
        }
    }
}

/// Chooses a PNG or SVG and how it's fitted.
struct ArtEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var art: ThemeArt?
    /// The layer the art belongs to, for the positioning preview.
    let surface: ThemeSurface
    var defaultMode = "fill"
    var defaultReplaces = false

    var body: some View {
        LabeledContent("Image") {
            HStack(spacing: 8) {
                AssetThumb(asset: art?.asset)
                Button(art == nil ? "Choose PNG or SVG…" : "Replace…") {
                    if let name = chooseAsset(model) {
                        var next = art ?? ThemeArt(mode: defaultMode, replacesFill: defaultReplaces)
                        next.asset = name
                        art = next
                    }
                }
                if art != nil { Button("Remove") { art = nil } }
            }
        }
        if art != nil {
            // A plain binding rather than unwrapping `$art`, so removing the image can't read a missing value.
            let a = Binding(get: { art ?? ThemeArt() }, set: { art = $0 })
            Picker("Fit", selection: a.mode) {
                Text("Fill (crop to cover)").tag("fill")
                Text("Fit (show all of it)").tag("fit")
                Text("Stretch").tag("stretch")
                Text("Tile").tag("tile")
                Text("Frame (corners stay, edges stretch)").tag("frame")
            }
            if a.wrappedValue.mode == "frame" {
                SliderRow(label: "Corner size", value: a.slice, range: 1...80, step: 1) { String(format: "%g pt", $0) }
            }
            if a.wrappedValue.canPosition {
                ArtPositioner(art: a, surface: surface)
                SliderRow(label: "Size", value: a.scale, range: 0.1...4, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
                SliderRow(label: "Left to right", value: a.x, range: 0...1, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                SliderRow(label: "Top to bottom", value: a.y, range: 0...1, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
            }
            SliderRow(label: "Opacity", value: a.opacity, range: 0...1, step: 0.05) { "\(Int(($0 * 100).rounded()))%" }
            Toggle("Show only the image (no fill or outline)", isOn: a.replacesFill)
        }
    }
}

/// A small copy of the layer where the art can be dragged into place. Positions are relative
/// (left to right, top to bottom), so the placement carries over to panels of any size.
struct ArtPositioner: View {
    @Binding var art: ThemeArt
    let surface: ThemeSurface
    @State private var start: (x: Double, y: Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Position")
                Spacer()
                Text("Drag the image to move it").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                Button("Center") { art.x = 0.5; art.y = 0.5 }
                    .controlSize(.small)
                    .disabled(art.x == 0.5 && art.y == 0.5)
                Button("Reset Size") { art.scale = 1 }
                    .controlSize(.small)
                    .disabled(art.scale == 1)
            }
            GeometryReader { geo in
                SurfaceShape(surface: preview)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag($0.translation, frame: geo.size) }
                            .onEnded { _ in start = nil }
                    )
            }
            .frame(height: 150)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }

    /// The layer as it is, except the art is always shown here (even at low opacity it stays findable).
    private var preview: ThemeSurface {
        var s = surface
        s.radius = min(s.radius, 16)
        s.art = art
        return s
    }

    private func drag(_ t: CGSize, frame: CGSize) {
        guard let image = ThemeStore.shared.image(art.asset) else { return }
        if start == nil { start = (art.x, art.y) }
        guard let start else { return }
        let r = ArtImage.placement(image: image.size, frame: frame, art: art)
        // How far the image can travel each way. For a tile it is one tile; otherwise the space
        // left over (negative when the image is larger than the frame, which flips the sign as it should).
        let travelX = art.mode == "tile" ? r.width : frame.width - r.width
        let travelY = art.mode == "tile" ? r.height : frame.height - r.height
        if abs(travelX) > 0.5 { art.x = min(max(start.x + t.width / travelX, 0), 1) }
        if abs(travelY) > 0.5 { art.y = min(max(start.y + t.height / travelY, 0), 1) }
    }
}

/// An optional extra image (button hover and pressed states).
struct AssetRow: View {
    @Environment(AppModel.self) private var model
    let label: String
    @Binding var asset: String?

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                AssetThumb(asset: asset)
                Button(asset == nil ? "Choose…" : "Replace…") {
                    if let name = chooseAsset(model) { asset = name }
                }
                if asset != nil { Button("Remove") { asset = nil } }
            }
        }
    }
}

struct AssetThumb: View {
    let asset: String?

    var body: some View {
        if let img = ThemeStore.shared.image(asset) {
            ZStack {
                Checkerboard()
                Image(nsImage: img).resizable().scaledToFit()
            }
            .frame(width: 44, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.gray.opacity(0.5)))
        }
    }
}

/// Asks for a PNG or SVG and copies it into the theme's art folder. Returns its stored name.
@MainActor
private func chooseAsset(_ model: AppModel) -> String? {
    let panel = NSOpenPanel()
    panel.title = "Choose a PNG or SVG image"
    panel.allowedContentTypes = [.png, .svg]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    do {
        return try ThemeStore.shared.addAsset(from: url)
    } catch {
        model.errorMessage = describe(error)
        return nil
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var format: (Double) -> String = { String(format: "%g", $0) }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().foregroundStyle(Ink.secondary).frame(width: 48, alignment: .trailing)
            }
        }
    }
}

struct FontPicker: View {
    let label: String
    @Binding var family: String

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()

    var body: some View {
        Picker(label, selection: $family) {
            Text("System").tag("system")
            Text("System Rounded").tag("rounded")
            Text("System Serif").tag("serif")
            Text("System Monospaced").tag("mono")
            Divider()
            // A profile from another Mac may name a font this one doesn't have.
            if !["system", "rounded", "serif", "mono"].contains(family) && !Self.families.contains(family) {
                Text("\(family) (not installed)").tag(family)
            }
            ForEach(Self.families, id: \.self) { Text($0).tag($0) }
        }
    }
}

// MARK: - Preview

/// A small sample of every themed piece, so changes are visible without leaving the window.
struct ThemePreview: View {
    @State private var sampleOn = true
    @State private var presses = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview").font(Font.app(.headline))
                Text("A sample of each piece, using the profile on screen.")
                    .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                HStack(spacing: 10) {
                    StatCard(title: "Cash", value: "$4,210.55", detail: "3 accounts")
                    StatCard(title: "Debt", value: "−$1,820.40", detail: "1 loan", tint: .negative)
                }
                Panel(title: "Panel") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Main text on a panel")
                        Text("Secondary text").foregroundStyle(Ink.secondary)
                        Text("Faint text").foregroundStyle(Ink.tertiary)
                        HStack(spacing: 10) {
                            Text("+$1,250.00").foregroundStyle(Color.positive)
                            Text("−$45.99").foregroundStyle(Color.negative)
                            Text("Not set").foregroundStyle(Color.warning)
                        }
                        .monospacedDigit()
                        HStack(spacing: 8) {
                            ForEach(["Mon", "Tue", "Wed"], id: \.self) { d in
                                VStack(alignment: .leading) {
                                    Text(d).font(Font.app(.caption))
                                    Text("card").font(Font.app(.caption2)).foregroundStyle(Ink.secondary)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .surface(.card, radius: 8, primary: true)
                            }
                        }
                        ProgressView(value: 0.62)
                    }
                }
                Divider()
                Text("Sample controls").font(Font.app(.subheadline).weight(.medium))
                HStack(spacing: 8) {
                    Button("Button") { presses += 1 }
                    Button("Main action") { presses += 1 }.buttonStyle(.themedProminent)
                    Button("Disabled") {}.disabled(true)
                }
                Toggle(sampleOn ? "A switch, on" : "A switch, off", isOn: $sampleOn).toggleStyle(.switch)
                Text(presses == 0 ? "These only show how buttons and switches will look. Try them: they don't change anything."
                     : "Pressed \(presses) time\(presses == 1 ? "" : "s"). These only show the look; they don't change anything.")
                    .font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}
