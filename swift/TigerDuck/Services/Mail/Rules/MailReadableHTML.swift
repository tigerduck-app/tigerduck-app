#if os(iOS)
import Foundation
import SwiftSoup
import os

/// A sanitized mail document, ready to draw on either page with its unreadable text fixed.
///
/// On a page, a text colour the sender set that reads under 4.5:1 (WCAG 2) on its background
/// moves to the nearest OKLCH lightness that reaches it, keeping its hue and as much chroma as
/// sRGB holds there. The background is the element's own or nearest ancestor's `background-color`
/// or `bgcolor`, else the page. Text on a background this cannot read keeps its colour, as does
/// every other colour. Only the values of `color` declarations and `<font color>` change.
nonisolated struct MailReadableHTML {
    static let minimumContrast = 4.5

    /// Whether the mail sets a text or background colour of its own anywhere.
    let setsColors: Bool
    private let html: String
    /// Held whole: a node finds its output settings through its document, which a node alone
    /// does not keep alive.
    private let document: Document?
    private let textColors: [TextColor]

    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.Contrast")

    init(_ html: String) {
        self.html = html
        var setsColors = false
        var textColors: [TextColor] = []
        var document: Document?
        do {
            let parsed = try SwiftSoup.parseBodyFragment(html)
            parsed.outputSettings().prettyPrint(pretty: false)
            document = parsed
            for element in try parsed.select("[style], [bgcolor], font[color]") {
                let style = Style(try element.attr("style"))
                if try Self.setsColor(element, style: style) { setsColors = true }
                if let textColor = try Self.textColor(of: element, style: style) { textColors.append(textColor) }
            }
        } catch {
            Self.logger.error("Mail colour read failed, colours left as sent: \(String(describing: type(of: error)), privacy: .public)")
            textColors = []
        }
        self.setsColors = setsColors
        self.document = document
        self.textColors = textColors
    }

    /// The document on a page of `background` (`0xRRGGBB`). Only values of attributes it already
    /// has change, and no foreign content survives the sanitizer for a value to steer the parser,
    /// so the page parses the same tree `MailHTMLSanitizer.rewriteLinks` checked.
    func html(onPage background: UInt32) -> String {
        guard let body = document?.body(), !textColors.isEmpty else { return html }
        let page = RGBA(background)
        var changed = false
        do {
            for textColor in textColors {
                let behind = textColor.backgrounds.reversed().reduce(page) { below, layer in layer.over(below) }
                var value = textColor.sent
                if let readable = Self.readable(textColor.color.over(behind), on: behind) {
                    value.replaceSubrange(textColor.range, with: readable.css)
                    changed = true
                }
                try textColor.element.attr(textColor.attribute, value)
            }
            return changed ? try body.html() : html
        } catch {
            Self.logger.error("Mail colour rewrite failed, colours left as sent: \(String(describing: type(of: error)), privacy: .public)")
            return html
        }
    }

    // MARK: The document

    /// A text colour the sender set, where its value is written, and what it is drawn on.
    private nonisolated struct TextColor {
        let element: Element
        /// `style`, or `<font>`'s `color`.
        let attribute: String
        let sent: String
        let range: Range<String.Index>
        let color: RGBA
        /// The element's own background and its ancestors', innermost first, up to the first
        /// opaque one. Short of an opaque one, the page shows through.
        let backgrounds: [RGBA]
    }

    /// A filtered `style` and its declarations. Each `value` is a slice of `text`, without
    /// `!important`, so it can be replaced where it stands.
    private nonisolated struct Style {
        nonisolated struct Declaration {
            let property: String
            let value: Substring
            let isImportant: Bool
        }

        let text: String
        let declarations: [Declaration]

        init(_ text: String) {
            self.text = text
            declarations = text.split(separator: ";").compactMap { piece in
                guard let colon = piece.firstIndex(of: ":") else { return nil }
                var value = MailReadableHTML.trimmed(piece[piece.index(after: colon)...])
                var isImportant = false
                if let bang = value.lastIndex(of: "!"),
                   value[value.index(after: bang)...].trimmingCharacters(in: .whitespaces).lowercased() == "important" {
                    value = MailReadableHTML.trimmed(value[..<bang])
                    isImportant = true
                }
                let property = piece[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return Declaration(property: property, value: value, isImportant: isImportant)
            }
        }

        /// The declaration of `property` that applies: the last `!important` one, else the last.
        func effective(_ property: String) -> Declaration? {
            let matching = declarations.filter { $0.property == property }
            return matching.last(where: \.isImportant) ?? matching.last
        }

        func declares(_ properties: Set<String>) -> Bool {
            declarations.contains { properties.contains($0.property) && $0.value.lowercased() != "none" }
        }
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var text = text.drop(while: \.isWhitespace)
        while text.last?.isWhitespace == true { text = text.dropLast() }
        return text
    }

    private static func setsColor(_ element: Element, style: Style) throws -> Bool {
        if style.declarations.contains(where: { $0.property == "color" || $0.property == "background-color" }) { return true }
        if !trimmed(try element.attr("bgcolor")[...]).isEmpty { return true }
        guard element.tagName() == "font" else { return false }
        return !trimmed(try element.attr("color")[...]).isEmpty
    }

    /// The colour `element` sets for its text, when it is drawn on backgrounds this can read. A
    /// `color` declaration outranks `<font color>`, even one this cannot read.
    private static func textColor(of element: Element, style: Style) throws -> TextColor? {
        let attribute: String, sent: String, value: Substring, legacy: Bool
        if let declaration = style.effective("color") {
            (attribute, sent, value, legacy) = ("style", style.text, declaration.value, false)
        } else if element.tagName() == "font", element.hasAttr("color") {
            let color = try element.attr("color")
            (attribute, sent, value, legacy) = ("color", color, trimmed(color[...]), true)
        } else {
            return nil
        }
        guard let color = parse(value, legacy: legacy), color.alpha > 0,
              let backgrounds = try backgrounds(behind: element) else { return nil }
        return TextColor(element: element, attribute: attribute, sent: sent, range: value.startIndex..<value.endIndex,
                         color: color, backgrounds: backgrounds)
    }

    /// `element`'s background and its ancestors', innermost first, up to the first opaque one;
    /// nil when one of them cannot be read. A `border-image` paints over the background, so it
    /// counts as one that cannot be read.
    private static func backgrounds(behind element: Element) throws -> [RGBA]? {
        var layers: [RGBA] = []
        var next: Element? = element
        while let node = next, (layers.last?.alpha ?? 0) < 1 {
            next = node.parent()
            let style = Style(try node.attr("style"))
            if style.declares(["border-image", "border-image-source"]) { return nil }
            let value: Substring, legacy: Bool
            if let declaration = style.effective("background-color") {
                (value, legacy) = (declaration.value, false)
            } else {
                (value, legacy) = (trimmed(try node.attr("bgcolor")[...]), true)
                if value.isEmpty { continue }
            }
            guard let layer = parse(value, legacy: legacy) else { return nil }
            if layer.alpha > 0 { layers.append(layer) }
        }
        return layers
    }

    // MARK: Colours

    /// An sRGB colour, each channel and the alpha from 0 to 1.
    nonisolated struct RGBA: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha = 1.0

        /// `#rrggbb`, from an opaque colour. Hex digits only, so the locale cannot change it.
        var css: String {
            let byte = { (channel: Double) in Int((channel * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
        }

        /// This colour drawn over the opaque `below`, in sRGB as browsers blend.
        func over(_ below: RGBA) -> RGBA {
            let mix = { (top: Double, bottom: Double) in top * alpha + bottom * (1 - alpha) }
            return RGBA(red: mix(red, below.red), green: mix(green, below.green), blue: mix(blue, below.blue))
        }
    }

    /// A CSS colour: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()` or a name. With
    /// `legacy`, a `bgcolor` or `<font color>`, only `#rgb`, `#rrggbb` and names: HTML reads any
    /// other form there by its own rules, not as CSS. Nil for anything else.
    static func parse(_ value: Substring, legacy: Bool) -> RGBA? {
        let value = value.lowercased()
        if value == "transparent" { return RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        if let named = namedColors[value] { return RGBA(named) }
        if value.hasPrefix("#") { return hex(value.dropFirst(), legacy: legacy) }
        return legacy ? nil : function(value)
    }

    private static func hex(_ digits: Substring, legacy: Bool) -> RGBA? {
        let values = digits.compactMap { $0.isASCII ? $0.hexDigitValue : nil }.map(Double.init)
        guard values.count == digits.count, (legacy ? [3, 6] : [3, 4, 6, 8]).contains(values.count) else { return nil }
        let channels = values.count <= 4
            ? values.map { $0 / 15 }
            : stride(from: 0, to: values.count, by: 2).map { (values[$0] * 16 + values[$0 + 1]) / 255 }
        return RGBA(red: channels[0], green: channels[1], blue: channels[2], alpha: channels.count > 3 ? channels[3] : 1)
    }

    /// `rgb()` or `rgba()` with commas or spaces; with commas the three channels are all numbers
    /// or all percentages, as CSS requires.
    private static func function(_ value: String) -> RGBA? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")"), ["rgb", "rgba"].contains(value[..<open]) else { return nil }
        let arguments = value[value.index(after: open)..<value.index(before: value.endIndex)]
        var channels: [Substring]
        var alpha: Substring?
        if arguments.contains(",") {
            channels = arguments.split(separator: ",", omittingEmptySubsequences: false).map(trimmed)
            guard channels.count == 3 || channels.count == 4 else { return nil }
            if channels.count == 4 { alpha = channels.removeLast() }
            guard Set(channels.map { $0.hasSuffix("%") }).count == 1 else { return nil }
        } else {
            let halves = arguments.split(separator: "/", omittingEmptySubsequences: false)
            guard halves.count <= 2 else { return nil }
            channels = halves[0].split(whereSeparator: \.isWhitespace)
            alpha = halves.count == 2 ? trimmed(halves[1]) : nil
        }
        let rgb = channels.compactMap { number($0, scale: 255) }
        guard channels.count == 3, rgb.count == 3 else { return nil }
        var opacity = 1.0
        if let alpha {
            guard let value = number(alpha, scale: 1) else { return nil }
            opacity = value
        }
        return RGBA(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: opacity)
    }

    /// A number out of `scale` or a percentage, clamped to 0...1 as CSS does. Only digits, signs,
    /// points and exponents: `Double(_:)` alone also takes `nan`, `inf` and hex floats.
    private static func number(_ text: Substring, scale: Double) -> Double? {
        let isPercentage = text.hasSuffix("%")
        let digits = isPercentage ? text.dropLast() : text
        guard !digits.isEmpty, digits.allSatisfy({ "0123456789.+-e".contains($0) }), let number = Double(digits) else { return nil }
        return min(max(number / (isPercentage ? 100 : scale), 0), 1)
    }

    // MARK: Contrast

    /// The WCAG 2 contrast ratio of two opaque colours.
    static func contrast(_ first: RGBA, _ second: RGBA) -> Double {
        let (one, other) = (luminance(first), luminance(second))
        return (max(one, other) + 0.05) / (min(one, other) + 0.05)
    }

    /// The colour nearest `text` in OKLCH lightness that reads at `minimumContrast` on
    /// `background`, or nil when `text` already does. Both opaque.
    static func readable(_ text: RGBA, on background: RGBA) -> RGBA? {
        guard contrast(text, background) < minimumContrast else { return nil }
        let lab = OKLab(text)
        return [nearest(lab, towards: 1, on: background), nearest(lab, towards: 0, on: background)]
            .compactMap { $0 }.min { $0.distance < $1.distance }?.color
    }

    /// The first lightness from `lab`'s towards `end` that reads on `background`, found by halving,
    /// and how far it moved; nil when even `end`, white or black, does not read. The channels
    /// round away from the background, so the rounded colour still reads.
    private static func nearest(_ lab: OKLab, towards end: Double, on background: RGBA) -> (color: RGBA, distance: Double)? {
        let reads = { (lightness: Double) in contrast(displayable(lab, lightness: lightness), background) >= minimumContrast }
        guard reads(end) else { return nil }
        var (fails, passes) = (lab.lightness, end)
        for _ in 0..<32 {
            let middle = (fails + passes) / 2
            if reads(middle) { passes = middle } else { fails = middle }
        }
        let rule: FloatingPointRoundingRule = end > lab.lightness ? .up : .down
        let color = displayable(lab, lightness: passes)
        let byte = { (channel: Double) in (channel * 255).rounded(rule) / 255 }
        return (RGBA(red: byte(color.red), green: byte(color.green), blue: byte(color.blue)), abs(passes - lab.lightness))
    }

    /// `lab` at `lightness`, with its hue and as much of its chroma as sRGB holds there.
    private static func displayable(_ lab: OKLab, lightness: Double) -> RGBA {
        let scaled = { (chroma: Double) in OKLab(lightness: lightness, a: lab.a * chroma, b: lab.b * chroma) }
        var (inside, outside) = (0.0, 1.0)
        if scaled(1).isInGamut {
            inside = 1
        } else {
            for _ in 0..<24 {
                let middle = (inside + outside) / 2
                if scaled(middle).isInGamut { inside = middle } else { outside = middle }
            }
        }
        let (red, green, blue) = scaled(inside).linearRGB
        let channel = { (linear: Double) in encoded(min(max(linear, 0), 1)) }
        return RGBA(red: channel(red), green: channel(green), blue: channel(blue))
    }

    private static func luminance(_ color: RGBA) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    /// OKLab coordinates. OKLCH's chroma and hue are the length and angle of `(a, b)`, so scaling
    /// both keeps the hue.
    private nonisolated struct OKLab {
        var lightness: Double
        var a: Double
        var b: Double

        init(lightness: Double, a: Double, b: Double) {
            (self.lightness, self.a, self.b) = (lightness, a, b)
        }

        init(_ color: RGBA) {
            let (red, green, blue) = (linear(color.red), linear(color.green), linear(color.blue))
            let l = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
            let m = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
            let s = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
            lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        }

        var linearRGB: (Double, Double, Double) {
            let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
            return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        }

        var isInGamut: Bool {
            let (red, green, blue) = linearRGB
            return [red, green, blue].allSatisfy { $0 >= -1e-9 && $0 <= 1 + 1e-9 }
        }
    }

    /// CSS Color 4's named colours, `0xRRGGBB`.
    private static let namedColors: [String: UInt32] = [
        "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4, "azure": 0xF0FFFF,
        "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000, "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF,
        "blueviolet": 0x8A2BE2, "brown": 0xA52A2A, "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00,
        "chocolate": 0xD2691E, "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
        "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B, "darkgray": 0xA9A9A9,
        "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B,
        "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00, "darkorchid": 0x9932CC, "darkred": 0x8B0000,
        "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F, "darkslateblue": 0x483D8B, "darkslategray": 0x2F4F4F,
        "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3, "deeppink": 0xFF1493,
        "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969, "dodgerblue": 0x1E90FF,
        "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22, "fuchsia": 0xFF00FF,
        "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF, "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080,
        "green": 0x008000, "greenyellow": 0xADFF2F, "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4,
        "indianred": 0xCD5C5C, "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
        "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6,
        "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3,
        "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A,
        "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
        "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA,
        "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3, "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371,
        "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
        "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1,
        "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000,
        "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
        "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093,
        "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F, "pink": 0xFFC0CB, "plum": 0xDDA0DD,
        "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xFF0000,
        "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513, "salmon": 0xFA8072,
        "sandybrown": 0xF4A460, "seagreen": 0x2E8B57, "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0,
        "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
        "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3, "white": 0xFFFFFF,
        "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
    ]
}

nonisolated extension MailReadableHTML.RGBA {
    /// `0xRRGGBB`, opaque.
    init(_ rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
#endif
