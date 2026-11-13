import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns an image from anywhere into a PNG this app made itself.
///
/// Theme art comes from files people pick and from theme files other people share, so its bytes
/// are never trusted and never kept. The image is decoded once, its pixels are drawn into a new
/// bitmap, and that bitmap is written as a fresh PNG. Nothing is copied from the source except
/// pixel colors, so text chunks, EXIF (including location), color profiles, extra frames,
/// unknown chunks and anything appended after the image cannot survive. SVGs are checked, drawn
/// once, and stored as PNG; SVG source is never stored or exported.
///
/// What this cannot do: data hidden in the pixel colors themselves (for example in the lowest
/// bit of each channel) is still there afterwards. It is only colors. Nothing in Ledgerline
/// reads pixels as anything else, so it can't run; removing it would mean degrading every image.
///
/// This file depends only on system frameworks so it can be compiled and tested by itself.
enum ArtSanitizer {
    /// Largest source file accepted.
    static let maxBytes = 12 * 1024 * 1024
    /// Largest width or height, in pixels.
    static let maxSide = 8192
    /// Largest pixel count (a little over an 8K screen).
    static let maxPixels = 36_000_000

    struct ArtError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// PNG bytes made by this app from `data`. `allowSVG` is for files the user picks themself;
    /// shared theme files may only carry PNG.
    static func cleanPNG(from data: Data, allowSVG: Bool) throws -> Data {
        guard data.count <= maxBytes else { throw ArtError("That image is larger than 12 MB.") }
        let decoded: (image: CGImage, dpi: Double)
        if data.starts(with: pngSignature) {
            decoded = try decodePNG(data)
        } else if allowSVG, looksLikeSVG(data) {
            decoded = try rasterizeSVG(data)
        } else {
            throw ArtError(allowSVG ? "Only PNG and SVG images can be used." : "Only PNG images can be used here.")
        }
        guard let png = encode(decoded.image, dpi: decoded.dpi) else { throw ArtError("That image couldn't be converted.") }
        return png
    }

    // MARK: PNG

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

    /// Width and height from the PNG header, read by hand so an oversized image is refused
    /// before any decoder sees it. Nil when the bytes don't start like a PNG.
    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(24))
        guard b.count == 24, Array(b[0..<8]) == pngSignature else { return nil }
        // The first chunk must be a 13-byte IHDR.
        guard b[8] == 0, b[9] == 0, b[10] == 0, b[11] == 13, Array(b[12..<16]) == [0x49, 0x48, 0x44, 0x52] else { return nil }
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        return (u32(16), u32(20))
    }

    static func sizeIsAllowed(_ width: Int, _ height: Int) -> Bool {
        width >= 1 && height >= 1 && width <= maxSide && height <= maxSide && width * height <= maxPixels
    }

    private static func decodePNG(_ data: Data) throws -> (CGImage, Double) {
        guard let header = pngSize(data) else { throw ArtError("That image couldn't be read.") }
        guard sizeIsAllowed(header.width, header.height) else {
            throw ArtError("That image is too large. The limit is \(maxSide) pixels on a side.")
        }
        // Only the PNG decoder may look at these bytes, whatever else they might also be.
        let options: [CFString: Any] = [kCGImageSourceTypeIdentifierHint: UTType.png.identifier, kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) >= 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
              image.width == header.width, image.height == header.height else {
            throw ArtError("That image couldn't be read.")
        }
        var dpi = 72.0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let d = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue {
            dpi = d
        }
        return (image, dpi)
    }

    // MARK: SVG

    private static func looksLikeSVG(_ data: Data) -> Bool {
        String(decoding: data.prefix(4096), as: UTF8.self).lowercased().contains("<svg")
    }

    private static func rasterizeSVG(_ data: Data) throws -> (CGImage, Double) {
        let safe = try checkedSVG(data)
        guard let src = NSImage(data: safe), src.isValid else { throw ArtError("That image couldn't be read.") }
        var size = src.size
        if !(size.width >= 1 && size.height >= 1 && size.width.isFinite && size.height.isFinite) { size = NSSize(width: 256, height: 256) }
        // Aim for about 1536 pixels on the long side, never more than 4096.
        let longest = max(size.width, size.height)
        let k = min(max(1536 / longest, 1), 6) * min(1, 4096 / longest)
        let w = max(1, Int(size.width * k)), h = max(1, Int(size.height * k))
        guard sizeIsAllowed(w, h),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw ArtError("That image couldn't be converted.")
        }
        // Set the point size before making the context, so drawing in points fills every pixel.
        rep.size = size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw ArtError("That image couldn't be converted.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        src.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { throw ArtError("That image couldn't be converted.") }
        // Recording the scale as DPI keeps the picture's size in points the same as the SVG's.
        return (image, 72 * Double(w) / Double(size.width))
    }

    /// Refuses any SVG that could reach outside itself, and returns the bytes to draw.
    /// An SVG may only use what is inside its own file: no scripts, no embedded or linked
    /// images, no links to other files or the network, no entity tricks.
    static func checkedSVG(_ data: Data) throws -> Data {
        guard var text = String(data: data, encoding: .utf8) else { throw ArtError("That SVG isn't plain UTF-8 text.") }
        // A bare DOCTYPE line (older drawing apps add one) is removed so nothing tries to fetch
        // the DTD. One that declares anything of its own is refused.
        while let start = text.range(of: "<!DOCTYPE", options: .caseInsensitive) {
            guard let end = text.range(of: ">", range: start.upperBound..<text.endIndex) else { throw refused("a broken DOCTYPE") }
            guard !text[start.lowerBound..<end.upperBound].contains("[") else { throw refused("entity declarations") }
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        guard text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw refused("entity declarations") }

        let cleaned = Data(text.utf8)
        let checker = SVGChecker()
        let parser = XMLParser(data: cleaned)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = checker
        let finished = parser.parse()
        if let problem = checker.problem { throw refused(problem) }
        guard finished, checker.sawRoot else { throw ArtError("That SVG couldn't be read.") }
        return cleaned
    }

    private static func refused(_ what: String) -> ArtError {
        ArtError("That SVG can't be used because it contains \(what). Theme art may only use what is inside its own file.")
    }

    /// True when CSS-like text refers to nothing outside the file.
    fileprivate static func cssIsLocal(_ value: String) -> Bool {
        let v = value.lowercased()
        // A backslash can spell "url(" in a way a plain search misses, so it is refused outright.
        if v.contains("\\") { return false }
        for banned in ["@import", "javascript:", "expression(", "image-set(", "image(", "src("] where v.contains(banned) { return false }
        var rest = Substring(v)
        while let hit = rest.range(of: "url(") {
            let target = rest[hit.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" || $0 == "'" }
            guard target.first == "#" else { return false }
            rest = rest[hit.upperBound...]
        }
        return true
    }

    private final class SVGChecker: NSObject, XMLParserDelegate {
        /// What was found that isn't allowed, in words that finish "it contains …".
        var problem: String?
        var sawRoot = false
        private var elements = 0
        private var depth = 0
        private var styleDepth = 0
        private var styleText = ""

        private static let blocked: [String: String] = [
            "script": "a script", "foreignobject": "embedded web content", "image": "an embedded or linked image",
            "feimage": "an embedded or linked image", "iframe": "embedded web content", "object": "embedded content",
            "embed": "embedded content", "audio": "embedded media", "video": "embedded media", "canvas": "embedded content",
            "handler": "a script", "listener": "a script", "animate": "animation", "animatetransform": "animation",
            "animatemotion": "animation", "animatecolor": "animation", "set": "animation", "discard": "animation",
            "font-face-uri": "a linked font", "color-profile": "a linked color profile", "cursor": "a linked cursor",
        ]

        private func fail(_ what: String, _ parser: XMLParser) {
            if problem == nil { problem = what }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = elementName.lowercased()
            if !sawRoot {
                guard name == "svg" else { return fail("something other than a drawing", parser) }
                sawRoot = true
            }
            elements += 1
            depth += 1
            guard elements <= 100_000, depth <= 256 else { return fail("too many parts", parser) }
            if let what = Self.blocked[name] { return fail(what, parser) }
            if name == "style" { styleDepth += 1 }
            for (key, value) in attributeDict {
                let attr = (key.split(separator: ":").last.map(String.init) ?? key).lowercased()
                if attr.hasPrefix("on") { return fail("a script", parser) }
                if attr == "href" || attr == "src" {
                    guard value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") else {
                        return fail("a link to another file or address", parser)
                    }
                }
                guard ArtSanitizer.cssIsLocal(value) else { return fail("a link to another file or address", parser) }
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1
            if elementName.lowercased() == "style" {
                styleDepth -= 1
                if styleDepth == 0 {
                    guard ArtSanitizer.cssIsLocal(styleText) else { return fail("a link to another file or address", parser) }
                    styleText = ""
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if styleDepth > 0 { styleText += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if styleDepth > 0 { styleText += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            fail("a linked style sheet or other instruction", parser)
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail("entity declarations", parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            fail("entity declarations", parser)
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
                    notationName: String?) {
            fail("entity declarations", parser)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            fail("entity declarations", parser)
            return nil
        }
    }

    // MARK: Writing

    /// Draws the picture into a new 8-bit sRGB bitmap and writes that as a PNG. The only thing
    /// carried over besides the pixels is the resolution, as one clamped number.
    private static func encode(_ image: CGImage, dpi: Double) -> Data? {
        let w = image.width, h = image.height
        guard sizeIsAllowed(w, h),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let fresh = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let safeDPI = dpi.isFinite ? min(max(dpi, 36), 1200) : 72
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: safeDPI, kCGImagePropertyDPIHeight: safeDPI]
        CGImageDestinationAddImage(dest, fresh, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
