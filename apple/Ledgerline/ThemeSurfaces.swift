import AppKit
import SwiftUI

// How a theme reaches the screen: layer backgrounds, button skins, the root modifier that
// every window applies, and the AppKit pass that colors and outlines the windows themselves.
// Under the System profile each piece falls through to the ordinary macOS look.

// MARK: - Layers

/// Fill, art and outline for one layer.
struct SurfaceShape: View {
    let surface: ThemeSurface
    /// Swaps the art image (button hover and pressed states).
    var assetOverride: String? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: surface.radius, style: .continuous)
        let image = surface.art.flatMap { ThemeStore.shared.image(assetOverride ?? $0.asset) }
        let artOnly = image != nil && surface.art?.replacesFill == true
        ZStack {
            if !artOnly { shape.fill(Color(themeHex: surface.fill)) }
            if let image, let art = surface.art {
                ArtImage(image: image, art: art).clipShape(shape)
            }
            if !artOnly && surface.outlineWidth > 0 {
                let line = Color(themeHex: surface.outline)
                shape.strokeBorder(line, lineWidth: surface.outlineWidth)
                    .shadow(color: surface.glow > 0 ? line : .clear, radius: surface.glow)
                    .shadow(color: surface.glow > 0 ? line.opacity(0.7) : .clear, radius: surface.glow / 3)
            }
        }
    }
}

struct ArtImage: View {
    let image: NSImage
    let art: ThemeArt

    var body: some View {
        Group {
            switch art.mode {
            case "stretch":
                Image(nsImage: image).resizable()
            case "frame":
                // Never let the fixed corners be larger than the image itself.
                let s = min(art.slice, min(image.size.width, image.size.height) / 2 - 0.5)
                Image(nsImage: image).resizable(capInsets: EdgeInsets(top: s, leading: s, bottom: s, trailing: s), resizingMode: .stretch)
            default:
                GeometryReader { geo in
                    let r = Self.placement(image: image.size, frame: geo.size, art: art)
                    if art.mode == "tile" {
                        // One extra tile each way, slid by the position, so the pattern shifts without leaving a gap.
                        Rectangle()
                            .fill(ImagePaint(image: Image(nsImage: image), scale: art.scale))
                            .frame(width: geo.size.width + r.width, height: geo.size.height + r.height)
                            .offset(x: r.minX, y: r.minY)
                    } else {
                        Image(nsImage: image).resizable()
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
                .clipped()
            }
        }
        .opacity(art.opacity)
        .allowsHitTesting(false)
    }

    /// Where the image is drawn inside a frame of the given size: its size from the fit and the
    /// size multiplier, its origin from the position. For "tile" the rect is one tile, and its
    /// origin is how far the pattern is slid (always between minus one tile and zero).
    static func placement(image: CGSize, frame: CGSize, art: ThemeArt) -> CGRect {
        guard image.width > 0, image.height > 0, frame.width > 0, frame.height > 0 else { return .zero }
        if art.mode == "tile" {
            let w = image.width * art.scale, h = image.height * art.scale
            return CGRect(x: -w * (1 - art.x), y: -h * (1 - art.y), width: w, height: h)
        }
        let sx = frame.width / image.width, sy = frame.height / image.height
        let s = (art.mode == "fit" ? min(sx, sy) : max(sx, sy)) * art.scale
        let w = image.width * s, h = image.height * s
        return CGRect(x: (frame.width - w) * art.x, y: (frame.height - h) * art.y, width: w, height: h)
    }
}

/// The background of a panel or card. `systemRadius` and `systemPrimary` describe what the
/// System profile draws there, so the standard look is unchanged.
struct SurfaceBackground: View {
    let kind: SurfaceKind
    var systemRadius: CGFloat = 10
    var systemPrimary = false

    var body: some View {
        let t = Theme.current
        if t.isSystem {
            RoundedRectangle(cornerRadius: systemRadius)
                .fill(systemPrimary ? AnyShapeStyle(.background) : AnyShapeStyle(.background.secondary))
        } else {
            SurfaceShape(surface: t.surface(kind))
        }
    }
}

extension View {
    /// Draws a theme layer behind this view.
    func surface(_ kind: SurfaceKind, radius: CGFloat = 10, primary: Bool = false) -> some View {
        background(SurfaceBackground(kind: kind, systemRadius: radius, systemPrimary: primary))
    }
}

/// Colors an icon with the theme's accent. The System profile keeps whatever macOS draws there.
private struct ThemedAccent: ViewModifier {
    func body(content: Content) -> some View {
        let t = Theme.current
        if t.isSystem { content } else { content.foregroundStyle(Color(themeHex: t.accent)) }
    }
}

extension View {
    func themedAccent() -> some View { modifier(ThemedAccent()) }
}

/// Window fill and art, behind a page. The window outline is drawn by `WindowSkinner`.
struct WindowBackdrop: View {
    var body: some View {
        let t = Theme.current
        if t.isSystem {
            Color.clear
        } else {
            SurfaceShape(surface: Self.flat(t.window)).ignoresSafeArea()
        }
    }

    private static func flat(_ window: ThemeSurface) -> ThemeSurface {
        var s = window
        s.outlineWidth = 0
        s.radius = 0
        return s
    }
}

struct SidebarBackdrop: View {
    var body: some View {
        let t = Theme.current
        if t.isSystem { Color.clear } else { SurfaceShape(surface: t.sidebar).ignoresSafeArea() }
    }
}

// MARK: - Buttons

enum ThemedButtonKind {
    case standard
    /// Filled with the accent color under the System profile.
    case prominent
    /// The sheet's default (Return key) button: left alone under the System profile, prominent in a theme.
    case defaultAction
}

/// The app-wide button style. System profile: the normal macOS button. Otherwise: the theme's skin.
struct ThemedButtonStyle: PrimitiveButtonStyle {
    var kind = ThemedButtonKind.standard

    func makeBody(configuration: Configuration) -> some View {
        ThemedButton(configuration: configuration, kind: kind)
    }
}

extension PrimitiveButtonStyle where Self == ThemedButtonStyle {
    static var themed: ThemedButtonStyle { ThemedButtonStyle(kind: .standard) }
    static var themedProminent: ThemedButtonStyle { ThemedButtonStyle(kind: .prominent) }
    static var themedDefault: ThemedButtonStyle { ThemedButtonStyle(kind: .defaultAction) }
}

private struct ThemedButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let kind: ThemedButtonKind

    var body: some View {
        if Theme.current.isSystem {
            if kind == .prominent {
                Button(configuration).buttonStyle(.borderedProminent)
            } else {
                Button(configuration).buttonStyle(.automatic)
            }
        } else {
            Button(configuration).buttonStyle(SkinButtonStyle(prominent: kind != .standard))
        }
    }
}

private struct SkinButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        SkinButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct SkinButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    var body: some View {
        let t = Theme.current
        let skin = prominent ? t.prominentButton : t.button
        let pressed = configuration.isPressed
        let stateAsset = pressed ? (skin.pressedAsset ?? skin.hoverAsset) : hovering ? skin.hoverAsset : nil
        let hasStateArt = skin.surface.art != nil && stateAsset != nil
        let (h, v): (CGFloat, CGFloat) = switch controlSize {
        case .mini: (6, 1)
        case .small: (8, 2)
        case .large, .extraLarge: (16, 7)
        default: (11, 4)
        }
        configuration.label
            .lineLimit(1)
            .foregroundStyle(configuration.role == .destructive && !prominent ? Color.negative : Color(themeHex: skin.text))
            .padding(.horizontal, h)
            .padding(.vertical, v)
            .background(SurfaceShape(surface: skin.surface, assetOverride: stateAsset))
            .overlay {
                // Without state images, show hover and press by lightening or darkening the button.
                if !hasStateArt && isEnabled && (pressed || hovering) {
                    RoundedRectangle(cornerRadius: skin.surface.radius, style: .continuous)
                        .fill(Color(themeHex: skin.text).opacity(pressed ? 0.22 : 0.1))
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Root

/// Applied once at the top of every window. Sets the text color, fonts and accent
/// that everything below inherits, and keeps the saved copy and the windows in step with edits.
struct ThemedRoot: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let t = Theme.current
        content
            .font(t.isSystem ? nil : Font.app(.body))
            .foregroundStyle(Ink.primary)
            .tint(t.isSystem ? nil : Color(themeHex: t.accent))
            .scrollContentBackground(t.isSystem ? .automatic : .hidden)
            .preferredColorScheme(t.isSystem ? model.colorScheme : (t.isDark ? .dark : .light))
            .background(WindowAccessor())
            .onChange(of: t, initial: true) { _, _ in
                ThemeStore.shared.themeChanged()
                WindowSkinner.shared.refresh()
            }
    }
}

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }

    /// Gives the buttons below this view the theme's skin. It goes on a window's content rather
    /// than on the window, so the buttons macOS adds to the title bar keep their own look.
    func themedControls() -> some View { buttonStyle(.themed) }
}

/// Tells the skinner when a window (or a sheet on it) appears.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowSkinner.shared.start()
        let v = NSView()
        DispatchQueue.main.async { WindowSkinner.shared.refresh() }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Windows

/// Colors each app window and draws the window outline. SwiftUI can't reach the title bar or
/// sheets from a view, so this works on the NSWindows directly: main windows, the Appearance
/// window, and sheets. System panels (open/save, alerts, menus) are left alone.
@MainActor
final class WindowSkinner {
    static let shared = WindowSkinner()

    private var started = false
    private var original: [ObjectIdentifier: Original] = [:]

    private struct Original {
        weak var window: NSWindow?
        let background: NSColor?
        let transparentTitlebar: Bool
    }

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willBeginSheetNotification,
                     NSWindow.didEndSheetNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    WindowSkinner.shared.refresh()
                    // A sheet's window is attached just after the notification.
                    DispatchQueue.main.async { WindowSkinner.shared.refresh() }
                }
            }
        }
    }

    func refresh() {
        let theme = Theme.current
        original = original.filter { $0.value.window != nil }
        for window in NSApp?.windows ?? [] where skins(window) {
            apply(theme, to: window)
        }
    }

    private func skins(_ window: NSWindow) -> Bool {
        if window is NSSavePanel || window is NSColorPanel || window is NSFontPanel { return false }
        let name = window.className
        for skip in ["Alert", "Popover", "Menu", "ToolTip", "StatusBar", "Sampler", "TouchBar"] where name.contains(skip) { return false }
        return window.styleMask.contains(.titled) || window.isSheet
    }

    private func apply(_ theme: Theme, to window: NSWindow) {
        let key = ObjectIdentifier(window)
        let frame = window.contentView?.superview
        let existing = frame?.subviews.compactMap { $0 as? WindowOutlineView }.first

        if theme.isSystem {
            existing?.removeFromSuperview()
            if let o = original.removeValue(forKey: key) {
                window.backgroundColor = o.background
                window.titlebarAppearsTransparent = o.transparentTitlebar
            }
            return
        }

        if original[key] == nil {
            original[key] = Original(window: window, background: window.backgroundColor, transparentTitlebar: window.titlebarAppearsTransparent)
        }
        window.backgroundColor = (RGBA(hex: theme.window.fill) ?? RGBA(r: 1, g: 1, b: 1)).nsColor.withAlphaComponent(1)
        window.titlebarAppearsTransparent = true

        guard let frame else { return }
        let outline = existing ?? {
            let v = WindowOutlineView(frame: frame.bounds)
            v.autoresizingMask = [.width, .height]
            frame.addSubview(v, positioned: .above, relativeTo: nil)
            return v
        }()
        outline.update(theme.window, fullScreen: window.styleMask.contains(.fullScreen))
    }
}

/// The outline (and glow) around a window's edge. It sits above the content and ignores clicks.
private final class WindowOutlineView: NSView {
    private let line = CAShapeLayer()
    private var surface: ThemeSurface?
    private var fullScreen = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.fillColor = nil
        layer?.addSublayer(line)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        redraw()
    }

    func update(_ surface: ThemeSurface, fullScreen: Bool) {
        self.surface = surface
        self.fullScreen = fullScreen
        redraw()
    }

    private func redraw() {
        guard let s = surface, s.outlineWidth > 0, !fullScreen, let color = RGBA(hex: s.outline) else {
            line.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.isHidden = false
        line.frame = bounds
        let inset = s.outlineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let r = max(0, min(s.radius - inset, min(rect.width, rect.height) / 2))
        line.path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        line.strokeColor = color.nsColor.cgColor
        line.lineWidth = s.outlineWidth
        line.shadowColor = color.nsColor.cgColor
        line.shadowOffset = .zero
        line.shadowRadius = s.glow
        line.shadowOpacity = s.glow > 0 ? 1 : 0
        CATransaction.commit()
    }
}
