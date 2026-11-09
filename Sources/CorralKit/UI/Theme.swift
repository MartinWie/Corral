import AppKit
import CorralCore

// MARK: - Color math (OKLab, WCAG contrast)

/// Linear-light sRGB triple in 0…1 (gamma-encoded when called `rgb`).
struct RGB: Equatable {
    var r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    var color: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var clamped: RGB { RGB(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1)) }
}

enum ColorMath {
    static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func toGamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    /// (L, a, b)
    static func oklab(_ c: RGB) -> (Double, Double, Double) {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func fromOklab(_ L: Double, _ a: Double, _ b: Double) -> RGB {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return RGB(toGamma(max(r, 0)), toGamma(max(g, 0)), toGamma(max(bb, 0))).clamped
    }

    static func lightness(_ c: RGB) -> Double { oklab(c).0 }

    /// Sets OKLab L (and scales chroma), keeping hue.
    static func withLightness(_ c: RGB, _ L: Double, chroma: Double = 1) -> RGB {
        let (_, a, b) = oklab(c)
        return fromOklab(min(max(L, 0), 1), a * chroma, b * chroma)
    }

    /// Plain sRGB mix: t = 0 → a, t = 1 → b.
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    /// `top` at `alpha` composited over `bottom`.
    static func over(_ top: RGB, _ bottom: RGB, _ alpha: Double) -> RGB { mix(bottom, top, alpha) }

    static func luminance(_ c: RGB) -> Double {
        0.2126 * toLinear(c.r) + 0.7152 * toLinear(c.g) + 0.0722 * toLinear(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Steps `c` away from `background` in OKLab L until the contrast reaches `target`.
    static func guarded(_ c: RGB, on background: RGB, target: Double) -> RGB {
        let dark = lightness(background) < 0.6
        var (L, a, b) = oklab(c)
        var out = c
        for _ in 0..<60 {
            if contrast(out, background) >= target { return out }
            L += dark ? 0.01 : -0.01
            a *= 0.97
            b *= 0.97
            out = fromOklab(min(max(L, 0), 1), a, b)
        }
        return out
    }

    static func hue(_ c: RGB) -> (degrees: Double, chroma: Double) {
        let (_, a, b) = oklab(c)
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (h, sqrt(a * a + b * b))
    }
}

// MARK: - Tokens

enum Surface: Hashable { case chrome, card, elevated }

/// Text and overlay colors for one surface, all resolved to opaque colors.
struct Ramp: Equatable {
    var surface: NSColor
    var primary, secondary, tertiary, quaternary: NSColor
    var hover, selected, pressed, sunken, hairline, hairlineStrong: NSColor
}

struct StatusColors: Equatable {
    var fill, text, onFill: NSColor
}

struct StatusPalette: Equatable {
    var needsInput, working, done, error: StatusColors
    /// Amber row wash (normal / selected) and its border, composited over chrome.
    var wash, washSelected, washBorder: NSColor
}

struct ThemeTokens: Equatable {
    var isChromeDark: Bool
    var isCardDark: Bool
    var chromeAppearance: NSAppearance?
    var cardAppearance: NSAppearance
    var chrome, elevated, card, cardElevated: NSColor
    var ramps: [Surface: Ramp]
    var status: StatusPalette
    var accent, onAccent: NSColor
    var cardEdge: NSColor

    func ramp(_ s: Surface) -> Ramp { ramps[s]! }

    static func == (a: ThemeTokens, b: ThemeTokens) -> Bool {
        a.chrome == b.chrome && a.card == b.card && a.accent == b.accent && a.isChromeDark == b.isChromeDark
            && a.ramps[.chrome] == b.ramps[.chrome] && a.chromeAppearance?.name == b.chromeAppearance?.name
    }

    static let defaultBackground = RGB(hex: 0x282C34)
    static let defaultForeground = RGB(hex: 0xFFFFFF)

    /// Everything derives from the terminal theme (background B, foreground F) and the window-theme setting.
    static func make(background: NSColor?, foreground: NSColor?, windowTheme: String?,
                     systemDark: Bool, increaseContrast: Bool, accent: NSColor) -> ThemeTokens {
        let B = background.map(RGB.init) ?? defaultBackground
        let F = foreground.map(RGB.init) ?? (ColorMath.lightness(B) < 0.6 ? defaultForeground : RGB(hex: 0x1D1D1F))
        let cardDark = ColorMath.lightness(B) < 0.6

        // Chrome source S/Fs per window-theme (§2.2).
        let mode = (windowTheme ?? "auto").lowercased()
        let pseudoDark = (RGB(hex: 0x232325), RGB(hex: 0xDCDCDC))
        let pseudoLight = (RGB(hex: 0xFFFFFF), RGB(hex: 0x1D1D1F))
        let S: RGB, Fs: RGB, chromeAppearance: NSAppearance?
        switch mode {
        case "system":
            (S, Fs) = systemDark ? pseudoDark : pseudoLight
            chromeAppearance = nil
        case "light":
            (S, Fs) = pseudoLight
            chromeAppearance = NSAppearance(named: .aqua)
        case "dark":
            (S, Fs) = pseudoDark
            chromeAppearance = NSAppearance(named: .darkAqua)
        default:
            (S, Fs) = (B, F)
            chromeAppearance = NSAppearance(named: cardDark ? .darkAqua : .aqua)
        }
        let chromeDark = ColorMath.lightness(S) < 0.6

        func chrome(of src: RGB, dark: Bool) -> RGB {
            let L = ColorMath.lightness(src)
            if dark { return ColorMath.withLightness(src, L >= 0.20 ? L - 0.035 : max(L + 0.035, 0.17), chroma: 0.85) }
            return ColorMath.withLightness(src, L - 0.035, chroma: 0.85)
        }
        func elevated(of src: RGB, chrome c: RGB, dark: Bool) -> RGB {
            if dark { return ColorMath.withLightness(src, max(ColorMath.lightness(c) + 0.06, 0.24), chroma: 0.9) }
            return ColorMath.mix(src, RGB(1, 1, 1), 0.6)
        }
        let chromeC = chrome(of: S, dark: chromeDark)
        let elevatedC = elevated(of: S, chrome: chromeC, dark: chromeDark)
        let cardChrome = chrome(of: B, dark: cardDark)
        let cardElevatedC = elevated(of: B, chrome: cardChrome, dark: cardDark)

        let ic = increaseContrast
        func ramp(surface X: RGB, fg: RGB, dark: Bool) -> Ramp {
            let P = ColorMath.guarded(fg, on: X, target: 7.0)
            let Sx = ColorMath.guarded(ColorMath.mix(P, X, 0.36), on: X, target: ic ? 7 : 4.5)
            let T = ColorMath.guarded(ColorMath.mix(P, X, 0.55), on: X, target: ic ? 4.5 : 3)
            let Q = ColorMath.mix(P, X, 0.74)
            func ov(_ alpha: Double) -> NSColor { ColorMath.over(P, X, ic ? min(alpha * 1.8, 0.30) : alpha).color }
            return Ramp(surface: X.color, primary: P.color, secondary: Sx.color, tertiary: T.color, quaternary: Q.color,
                        hover: ov(dark ? 0.05 : 0.045), selected: ov(dark ? 0.10 : 0.08), pressed: ov(dark ? 0.14 : 0.12),
                        sunken: ov(dark ? 0.05 : 0.045), hairline: ov(dark ? 0.10 : 0.12),
                        hairlineStrong: ov(dark ? 0.16 : 0.18))
        }
        let ramps: [Surface: Ramp] = [
            .chrome: ramp(surface: chromeC, fg: Fs, dark: chromeDark),
            .card: ramp(surface: B, fg: F, dark: cardDark),
            .elevated: ramp(surface: elevatedC, fg: Fs, dark: chromeDark),
        ]

        // Status colors (§2.5), resolved by chrome darkness.
        let d = chromeDark
        func shift(_ c: RGB) -> RGB {
            ic ? ColorMath.withLightness(c, ColorMath.lightness(c) + (d ? 0.06 : -0.06)) : c
        }
        func status(_ fillD: UInt32, _ fillL: UInt32, _ textD: UInt32, _ textL: UInt32, _ onD: UInt32, _ onL: UInt32) -> StatusColors {
            let fill = shift(RGB(hex: d ? fillD : fillL))
            let text = ColorMath.guarded(RGB(hex: d ? textD : textL), on: chromeC, target: 4.5)
            return StatusColors(fill: fill.color, text: text.color, onFill: RGB(hex: d ? onD : onL).color)
        }
        var amber = status(0xFFB224, 0xB86E00, 0xFFC95C, 0x9A5800, 0x2A1700, 0xFFFFFF)
        let amberFill = RGB(amber.fill)
        let wash = ColorMath.over(amberFill, chromeC, d ? 0.16 : 0.14)
        // Amber text must also read on its own wash.
        amber.text = ColorMath.guarded(RGB(amber.text), on: wash, target: 4.5).color
        let palette = StatusPalette(
            needsInput: amber,
            working: status(0x4CC2FF, 0x0A74C2, 0x7FD3FF, 0x0A5F9E, 0x00131F, 0xFFFFFF),
            done: status(0x3DD68C, 0x178A4A, 0x5BE3A0, 0x18794E, 0x052914, 0xFFFFFF),
            error: status(0xFF6369, 0xD1343A, 0xFF8A8E, 0xB42318, 0x2B0A0B, 0xFFFFFF),
            wash: wash.color,
            washSelected: ColorMath.over(amberFill, chromeC, d ? 0.22 : 0.20).color,
            washBorder: ColorMath.over(amberFill, chromeC, d ? 0.35 : 0.40).color)

        // Accent (§2.6): clamped, and never mistaken for a status hue.
        var acc = RGB(accent)
        let L = ColorMath.lightness(acc)
        acc = ColorMath.withLightness(acc, d ? min(max(L, 0.68), 0.80) : min(max(L, 0.48), 0.60))
        let (h, chroma) = ColorMath.hue(acc)
        func near(_ target: Double) -> Bool { abs((h - target + 540).truncatingRemainder(dividingBy: 360) - 180) <= 30 }
        let accentColor: RGB = (chroma < 0.04 || near(75) || near(22) || near(155)) ? RGB(ramps[.chrome]!.secondary) : acc
        let onAccent = ColorMath.contrast(RGB(1, 1, 1), accentColor) >= ColorMath.contrast(RGB(0, 0, 0), accentColor)
            ? NSColor.white : NSColor.black

        return ThemeTokens(
            isChromeDark: chromeDark, isCardDark: cardDark,
            chromeAppearance: chromeAppearance, cardAppearance: NSAppearance(named: cardDark ? .darkAqua : .aqua)!,
            chrome: chromeC.color, elevated: elevatedC.color, card: B.color, cardElevated: cardElevatedC.color,
            ramps: ramps, status: palette, accent: accentColor.color, onAccent: onAccent,
            cardEdge: cardDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.10))
    }
}

extension Notification.Name {
    static let corralThemeDidChange = Notification.Name("CorralThemeDidChange")
    static let corralMotionChanged = Notification.Name("CorralMotionChanged")
}

/// The current tokens; recomputed from the terminal factory and system settings.

enum Theme {
    private(set) static var current = ThemeTokens.make(background: nil, foreground: nil, windowTheme: nil,
                                                       systemDark: true, increaseContrast: false,
                                                       accent: .controlAccentColor)
    private static var source: (NSColor?, NSColor?, String?) = (nil, nil, nil)

    /// Recomputes; posts `.corralThemeDidChange` when anything changed.
    @discardableResult
    static func update(background: NSColor?, foreground: NSColor?, windowTheme: String?) -> Bool {
        source = (background, foreground, windowTheme)
        return recompute()
    }

    @discardableResult
    static func recompute() -> Bool {
        let systemDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let next = ThemeTokens.make(background: source.0, foreground: source.1, windowTheme: source.2,
                                    systemDark: systemDark,
                                    increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                                    accent: .controlAccentColor)
        guard next != current || next.ramps != current.ramps else { return false }
        current = next
        GlyphCache.flush()
        NotificationCenter.default.post(name: .corralThemeDidChange, object: nil)
        return true
    }

    static var tokens: ThemeTokens { current }
    static func ramp(_ s: Surface) -> Ramp { current.ramp(s) }
}

// MARK: - Fonts

enum Fonts {
    static let rowTitle = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let rowTitleMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let rowTitleStrong = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let rowSub = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let rowSubStrong = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let rowTime = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    static let folder = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let section = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    static let compact = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let compactStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let badge = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
    static let statusline = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    static let keycap = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    static let query = NSFont.systemFont(ofSize: 18, weight: .regular)
    static let hitTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let hitSnippet = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let hitSnippetStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let hitCode = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let hitMeta = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let pageTitle = NSFont.systemFont(ofSize: 20, weight: .semibold)
    static let pageBody = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let pageMono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let captionMedium = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let body13Medium = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    /// Section labels: uppercase with tracking.
    static func sectionString(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [.font: section, .kern: 0.8, .foregroundColor: color])
    }
}

// MARK: - Glyph cache

/// SF Symbol images rendered once per (symbol, size, weight, colors, scale).

enum GlyphCache {
    private struct Key: Hashable {
        var name: String
        var size: CGFloat
        var weight: Int
        var colors: [String]
        var scale: CGFloat
    }

    private static var images: [Key: NSImage] = [:]
    private static var cgImages: [Key: CGImage] = [:]

    static func flush() {
        images.removeAll()
        cgImages.removeAll()
    }

    /// `colors`: one color = monochrome tint; two = palette [innerMark, shapeFill].
    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, colors: [NSColor],
                      scale: CGFloat = 2) -> NSImage? {
        let key = Key(name: name, size: size, weight: Int(weight.rawValue * 1000), colors: colors.map { RGB($0).hex + "\($0.alphaComponent)" }, scale: scale)
        if let hit = images[key] { return hit }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? fallback(name, size: size, color: colors.first ?? .labelColor)
        guard let base else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: colors.isEmpty ? [.labelColor] : colors))
        let img = base.withSymbolConfiguration(config) ?? base
        images[key] = img
        return img
    }

    /// Rasterized once per key: hot paths (row icons, glyph views) must not redraw bitmaps.
    static func cgImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, colors: [NSColor],
                        scale: CGFloat = 2) -> CGImage? {
        let key = Key(name: name, size: size, weight: Int(weight.rawValue * 1000), colors: colors.map { RGB($0).hex + "\($0.alphaComponent)" }, scale: scale)
        if let hit = cgImages[key] { return hit }
        let made = rasterize(name, size: size, weight: weight, colors: colors, scale: scale)
        if let made { cgImages[key] = made }
        return made
    }

    private static func rasterize(_ name: String, size: CGFloat, weight: NSFont.Weight, colors: [NSColor],
                                  scale: CGFloat) -> CGImage? {
        guard let img = image(name, size: size, weight: weight, colors: colors, scale: scale) else { return nil }
        var rect = NSRect(origin: .zero, size: img.size)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(img.size.width * scale)),
                                   pixelsHigh: Int(ceil(img.size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return img.cgImage(forProposedRect: &rect, context: nil, hints: nil) }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Drawn stand-in for symbols that don't exist (e.g. "pi" on older systems).
    private static func fallback(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        guard name == "pi" else { return nil }
        let font = NSFont.monospacedSystemFont(ofSize: size + 1, weight: .semibold)
        let text = NSAttributedString(string: "π", attributes: [.font: font, .foregroundColor: color])
        let s = text.size()
        return NSImage(size: NSSize(width: ceil(s.width), height: ceil(s.height)), flipped: false) { r in
            text.draw(in: r)
            return true
        }
    }

    static func agentSymbol(_ agent: AgentKind) -> String {
        switch agent {
        case .shell: return "terminal"
        case .claude: return "sparkle"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .pi: return "pi"
        }
    }
}

// MARK: - Shortcut hints

/// Reads the real key equivalents from the main menu (users can customize them), so hints never go stale.

enum KeyHint {
    /// `tag`: the item with that tag (Session 1… 9 share one action); nil takes the first.
    static func string(for action: Selector, tag: Int? = nil) -> String? {
        guard let item = item(for: action, tag: tag), !item.keyEquivalent.isEmpty else { return nil }
        return format(item.keyEquivalent, item.keyEquivalentModifierMask)
    }

    static func item(for action: Selector, tag: Int? = nil) -> NSMenuItem? {
        NSApp?.mainMenu.flatMap { find(action, tag: tag, in: $0) }
    }

    static func format(_ key: String, _ mods: NSEvent.ModifierFlags) -> String {
        let s = modifierGlyphs(mods).joined()
        return s + keyName(key)
    }

    /// A key as menus print it: ↩, ⇥, ⌫, arrows, F5, Space; letters uppercased.
    static func keyName(_ key: String) -> String {
        if let n = KeyCombo.functionKeyNumber(key) { return "F\(n)" }
        switch key.unicodeScalars.first.map({ Int($0.value) }) ?? 0 {
        case 0x0d: return "↩"
        case 0x1b: return "esc"
        case 0x09: return "⇥"
        case 0x08, 0x7f: return "⌫"
        case 0x20: return "Space"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        case NSDeleteFunctionKey: return "⌦"
        default: return key.uppercased()
        }
    }

    /// Modifier glyphs in menu order (⌃⌥⇧⌘), one per held modifier.
    static func modifierGlyphs(_ mods: NSEvent.ModifierFlags) -> [String] {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { mods.contains($0.0) }.map(\.1)
    }

    private static func find(_ action: Selector, tag: Int?, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action, tag == nil || item.tag == tag { return item }
            if let sub = item.submenu, let hit = find(action, tag: tag, in: sub) { return hit }
        }
        return nil
    }
}
