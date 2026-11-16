import AppKit
import SwiftUI

// The color picker: a hue ring around a triangle. The triangle's corners are the pure hue,
// white and black, so moving toward white lowers saturation and toward black lowers value.

// MARK: - Geometry

private struct WheelGeometry {
    let center: CGPoint
    /// Outer and inner radius of the hue ring.
    let outer: CGFloat
    let inner: CGFloat
    /// Distance from the center to each triangle corner.
    let tri: CGFloat

    init(size: CGSize) {
        let side = min(size.width, size.height)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        outer = side / 2 - 2
        inner = outer - max(16, side * 0.095)
        tri = inner - 5
    }

    /// Barycentric weights (hue, white, black) of a point in the triangle's own frame, where the
    /// hue corner points right. Points outside are pulled back onto the triangle.
    func weights(x: CGFloat, y: CGFloat) -> (h: Double, w: Double, b: Double) {
        let px = Double(x / tri), py = Double(y / tri), s3 = 3.0.squareRoot()
        var h = max(0, (1 + 2 * px) / 3)
        var w = max(0, (1 - px + s3 * py) / 3)
        var b = max(0, (1 - px - s3 * py) / 3)
        let sum = h + w + b
        h /= sum; w /= sum; b /= sum
        return (h, w, b)
    }

    /// Where a saturation/value pair sits, in the view's coordinates.
    func point(hue: Double, s: Double, v: Double) -> CGPoint {
        let s3 = 3.0.squareRoot()
        let wh = v * s, ww = v * (1 - s), wb = 1 - v
        let x = (wh - ww / 2 - wb / 2) * Double(tri)
        let y = (ww - wb) * s3 / 2 * Double(tri)
        let a = hue * 2 * .pi
        return CGPoint(x: center.x + CGFloat(x * cos(a) - y * sin(a)), y: center.y + CGFloat(x * sin(a) + y * cos(a)))
    }
}

/// Renders the triangle for one hue. Layered gradients can't reproduce it exactly, so it's computed per pixel.
private final class TriangleRenderer {
    static let shared = TriangleRenderer()
    private var key = (hue: -1, pixels: 0)
    private var cached: CGImage?

    func image(hue: Double, pixels n: Int) -> CGImage? {
        let hk = Int((hue * 3600).rounded())
        if key == (hk, n), let cached { return cached }
        guard n > 0 else { return nil }
        let pure = HSVA(h: hue, s: 1, v: 1).rgba
        let r = Double(n) / 2, s3 = 3.0.squareRoot()
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for row in 0..<n {
            let py = (Double(row) + 0.5 - r) / r
            for col in 0..<n {
                let px = (Double(col) + 0.5 - r) / r
                var h = max(0, (1 + 2 * px) / 3)
                var w = max(0, (1 - px + s3 * py) / 3)
                let b = max(0, (1 - px - s3 * py) / 3)
                let sum = h + w + b
                h /= sum; w /= sum
                let i = (row * n + col) * 4
                bytes[i] = UInt8(min(255, (h * pure.r + w) * 255 + 0.5))
                bytes[i + 1] = UInt8(min(255, (h * pure.g + w) * 255 + 0.5))
                bytes[i + 2] = UInt8(min(255, (h * pure.b + w) * 255 + 0.5))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        cached = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                         decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        key = (hk, n)
        return cached
    }
}

// MARK: - Wheel

struct HSVTriangleWheel: View {
    @Binding var hsva: HSVA
    @Environment(\.displayScale) private var displayScale
    @State private var target: Target?

    private enum Target { case ring, triangle }

    private static let hues: [Color] = (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) }

    var body: some View {
        GeometryReader { geo in
            let g = WheelGeometry(size: geo.size)
            Canvas { ctx, _ in draw(&ctx, g) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag($0.location, g) }
                        .onEnded { _ in target = nil }
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Color wheel")
    }

    private func draw(_ ctx: inout GraphicsContext, _ g: WheelGeometry) {
        let c = g.center
        var ring = Path()
        ring.addEllipse(in: CGRect(x: c.x - g.outer, y: c.y - g.outer, width: g.outer * 2, height: g.outer * 2))
        ring.addEllipse(in: CGRect(x: c.x - g.inner, y: c.y - g.inner, width: g.inner * 2, height: g.inner * 2))
        ctx.fill(ring, with: .conicGradient(Gradient(colors: Self.hues), center: c, angle: .zero), style: FillStyle(eoFill: true))

        let angle = hsva.h * 2 * .pi
        let s3 = CGFloat(3.0.squareRoot())
        var tctx = ctx
        tctx.translateBy(x: c.x, y: c.y)
        tctx.rotate(by: .radians(angle))
        var tri = Path()
        tri.move(to: CGPoint(x: g.tri, y: 0))
        tri.addLine(to: CGPoint(x: -g.tri / 2, y: g.tri * s3 / 2))
        tri.addLine(to: CGPoint(x: -g.tri / 2, y: -g.tri * s3 / 2))
        tri.closeSubpath()
        tctx.clip(to: tri)
        if let img = TriangleRenderer.shared.image(hue: hsva.h, pixels: Int(g.tri * 2 * displayScale)) {
            tctx.draw(Image(decorative: img, scale: 1), in: CGRect(x: -g.tri, y: -g.tri, width: g.tri * 2, height: g.tri * 2))
        }

        // Hue marker on the ring.
        let mid = (g.outer + g.inner) / 2
        let hp = CGPoint(x: c.x + mid * CGFloat(cos(angle)), y: c.y + mid * CGFloat(sin(angle)))
        marker(&ctx, at: hp, radius: (g.outer - g.inner) / 2 - 2, dark: false)
        // Saturation/value marker in the triangle.
        marker(&ctx, at: g.point(hue: hsva.h, s: hsva.s, v: hsva.v), radius: 6, dark: hsva.v > 0.6 && hsva.s < 0.5)
    }

    private func marker(_ ctx: inout GraphicsContext, at p: CGPoint, radius: CGFloat, dark: Bool) {
        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.45)), lineWidth: 1)
        ctx.stroke(Path(ellipseIn: rect), with: .color(dark ? .black : .white), lineWidth: 2)
    }

    private func drag(_ p: CGPoint, _ g: WheelGeometry) {
        let dx = p.x - g.center.x, dy = p.y - g.center.y
        if target == nil { target = hypot(dx, dy) >= g.inner - 1 ? .ring : .triangle }
        switch target {
        case .ring:
            var a = atan2(Double(dy), Double(dx))
            if a < 0 { a += 2 * .pi }
            hsva.h = min(a / (2 * .pi), 0.99999)
        case .triangle:
            // Turn the point into the triangle's own frame (hue corner pointing right).
            let a = -hsva.h * 2 * .pi
            let x = dx * CGFloat(cos(a)) - dy * CGFloat(sin(a))
            let y = dx * CGFloat(sin(a)) + dy * CGFloat(cos(a))
            let w = g.weights(x: x, y: y)
            let v = w.h + w.w
            hsva.v = min(max(v, 0), 1)
            // At black, saturation has no meaning; keep the last one so the marker doesn't jump.
            if v > 0.0001 { hsva.s = min(max(w.h / v, 0), 1) }
        case nil:
            break
        }
    }
}

// MARK: - Picker panel

/// The full picker: wheel, opacity, numeric fields, eyedropper and the theme's own colors.
struct TriangleColorPicker: View {
    @Binding var hex: String
    var supportsOpacity = true

    @State private var hsva = HSVA(h: 0, s: 0, v: 1)
    @State private var original = ""
    @State private var hexText = ""

    var body: some View {
        VStack(spacing: 10) {
            HSVTriangleWheel(hsva: $hsva).frame(width: 220, height: 220)

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    swatch(hsva.rgba.hex).help("New")
                    Button { apply(original) } label: { swatch(original) }
                        .buttonStyle(.plain)
                        .help("Original (click to go back)")
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.gray.opacity(0.5)))
                Button { sample() } label: { Image(systemName: "eyedropper") }
                    .help("Pick a color from the screen")
                Spacer()
                Text("#").foregroundStyle(Ink.secondary)
                TextField("", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 86)
                    .onSubmit { apply(hexText) }
            }

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    field("H", value: hsva.h * 360, max: 360) { hsva.h = min($0 / 360, 0.99999) }
                    field("S", value: hsva.s * 100, max: 100) { hsva.s = $0 / 100 }
                    field("B", value: hsva.v * 100, max: 100) { hsva.v = $0 / 100 }
                }
                GridRow {
                    field("R", value: hsva.rgba.r * 255, max: 255) { setRGB(r: $0 / 255) }
                    field("G", value: hsva.rgba.g * 255, max: 255) { setRGB(g: $0 / 255) }
                    field("B", value: hsva.rgba.b * 255, max: 255) { setRGB(b: $0 / 255) }
                }
            }

            if supportsOpacity {
                HStack {
                    Text("Opacity").foregroundStyle(Ink.secondary)
                    Slider(value: $hsva.a, in: 0...1)
                    Text("\(Int((hsva.a * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }

            let palette = Theme.current.palette
            if !palette.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Colors in this theme").font(Font.app(.caption)).foregroundStyle(Ink.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 4), count: 11), spacing: 4) {
                        ForEach(palette, id: \.self) { c in
                            Button { apply(c) } label: {
                                ZStack {
                                    Checkerboard()
                                    Color(themeHex: c)
                                }
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.gray.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                            .help(c)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Font.app(.callout))
        .padding(14)
        .frame(width: 290)
        .themedControls()
        .onAppear {
            original = hex
            load(hex)
        }
        .onChange(of: hsva) { _, new in
            var out = new.rgba
            if !supportsOpacity { out.a = 1 }
            let s = out.hex
            hexText = String(s.dropFirst())
            if RGBA(hex: hex)?.hex != s { hex = s }
        }
        .onChange(of: hex) { _, new in
            // Changed from outside (Revert, another profile): follow it.
            if RGBA(hex: new)?.hex != hsva.rgba.hex { load(new) }
        }
    }

    private func swatch(_ value: String) -> some View {
        ZStack {
            Checkerboard()
            Color(themeHex: value)
        }
        .frame(width: 34, height: 24)
    }

    private func field(_ label: String, value: Double, max: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(Ink.secondary).frame(width: 12)
            TextField("", value: Binding(get: { Int(value.rounded()) }, set: { set(min(Swift.max(Double($0), 0), max)) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
        }
    }

    /// Keeps the hue when the color has none of its own (grays), so the triangle doesn't spin.
    private func load(_ value: String) {
        guard let rgba = RGBA(hex: value) else { return }
        var next = rgba.hsva
        if next.s < 0.0001 || next.v < 0.0001 { next.h = hsva.h }
        if next.v < 0.0001 { next.s = hsva.s }
        hsva = next
        hexText = String(rgba.hex.dropFirst())
    }

    private func apply(_ value: String) {
        guard var rgba = RGBA(hex: value) else {
            hexText = String(hsva.rgba.hex.dropFirst())
            return
        }
        if !supportsOpacity { rgba.a = 1 }
        load(rgba.hex)
    }

    private func setRGB(r: Double? = nil, g: Double? = nil, b: Double? = nil) {
        var c = hsva.rgba
        if let r { c.r = r }
        if let g { c.g = g }
        if let b { c.b = b }
        load(c.hex)
    }

    private func sample() {
        NSColorSampler().show { picked in
            guard let c = picked?.usingColorSpace(.sRGB) else { return }
            apply(RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: hsva.a).hex)
        }
    }
}

/// Gray squares that show through a translucent color.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 5
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var dark = Path()
            for row in 0...Int(size.height / s) {
                for col in 0...Int(size.width / s) where (row + col) % 2 == 1 {
                    dark.addRect(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s))
                }
            }
            ctx.fill(dark, with: .color(Color(white: 0.78)))
        }
    }
}

// MARK: - Color wells

/// A swatch that opens the triangle picker. Edits a theme color string.
struct ThemeColorWell: View {
    @Binding var hex: String
    var supportsOpacity = true
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            ZStack {
                Checkerboard()
                Color(themeHex: hex)
            }
            .frame(width: 44, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.gray.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .trailing) {
            TriangleColorPicker(hex: $hex, supportsOpacity: supportsOpacity)
        }
    }
}

/// A labeled row for a theme color: the well plus its value.
struct ThemeColorRow: View {
    let label: String
    @Binding var hex: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(hex).font(.system(.caption, design: .monospaced)).foregroundStyle(Ink.secondary).textSelection(.enabled)
                ThemeColorWell(hex: $hex)
            }
        }
    }
}

/// The triangle picker for an ordinary `Color` value (account and category colors).
struct TriangleColorField: View {
    let label: String
    @Binding var selection: Color

    var body: some View {
        LabeledContent(label) {
            ThemeColorWell(hex: Binding(get: { selection.hexString }, set: { selection = Color(hex: $0) }), supportsOpacity: false)
        }
    }
}
