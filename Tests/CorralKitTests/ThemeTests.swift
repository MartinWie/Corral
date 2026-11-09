import AppKit
import Testing
@testable import CorralKit

@MainActor
struct ThemeTests {
    static let palettes: [(String, UInt32, UInt32)] = [
        ("Ghostty default", 0x282C34, 0xFFFFFF), ("Catppuccin Mocha", 0x1E1E2E, 0xCDD6F4),
        ("Tokyo Night", 0x1A1B26, 0xC0CAF5), ("Pure black", 0x000000, 0xFFFFFF),
        ("Solarized Light", 0xFDF6E3, 0x657B83), ("GitHub Light", 0xFFFFFF, 0x1F2328),
        ("Gruvbox Light", 0xFBF1C7, 0x3C3836),
    ]

    func tokens(_ bg: UInt32, _ fg: UInt32, theme: String? = nil, contrast: Bool = false,
                accent: NSColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)) -> ThemeTokens {
        ThemeTokens.make(background: RGB(hex: bg).color, foreground: RGB(hex: fg).color, windowTheme: theme,
                         systemDark: true, increaseContrast: contrast, accent: accent)
    }

    func cr(_ a: NSColor, _ b: NSColor) -> Double { ColorMath.contrast(RGB(a), RGB(b)) }

    @Test func textRampsMeetContrastOnEverySurface() {
        for (name, bg, fg) in Self.palettes {
            let t = tokens(bg, fg)
            for surface in [Surface.chrome, .card, .elevated] {
                let r = t.ramp(surface)
                #expect(cr(r.primary, r.surface) >= 6.9, "\(name) \(surface) primary")
                #expect(cr(r.secondary, r.surface) >= 4.45, "\(name) \(surface) secondary")
                #expect(cr(r.tertiary, r.surface) >= 2.95, "\(name) \(surface) tertiary")
            }
            for s in [t.status.needsInput, t.status.working, t.status.done, t.status.error] {
                #expect(cr(s.fill, t.chrome) >= 2.9, "\(name) status fill")
                #expect(cr(s.text, t.chrome) >= 4.45, "\(name) status text")
            }
            #expect(cr(t.status.needsInput.text, t.status.wash) >= 4.45, "\(name) amber text on wash")
        }
    }

    @Test func chromeFollowsTheTerminalTheme() {
        let dark = tokens(0x1E1E2E, 0xCDD6F4)
        #expect(dark.isChromeDark && dark.isCardDark)
        #expect(dark.chromeAppearance?.name == .darkAqua)
        #expect(RGB(dark.chrome).hex == "#161623")
        let light = tokens(0xFDF6E3, 0x657B83)
        #expect(!light.isChromeDark)
        #expect(light.chromeAppearance?.name == .aqua)
        #expect(RGB(light.card).hex == "#FDF6E3")
    }

    @Test func windowThemeModes() {
        #expect(tokens(0x1E1E2E, 0xCDD6F4, theme: "system").chromeAppearance == nil)
        #expect(tokens(0x1E1E2E, 0xCDD6F4, theme: "light").isChromeDark == false)
        #expect(tokens(0xFFFFFF, 0x000000, theme: "dark").isChromeDark == true)
        // The card always shows the terminal background.
        #expect(RGB(tokens(0xFFFFFF, 0x000000, theme: "dark").card).hex == "#FFFFFF")
        let none = ThemeTokens.make(background: nil, foreground: nil, windowTheme: nil, systemDark: false,
                                    increaseContrast: false, accent: .systemBlue)
        #expect(none.isChromeDark)
    }

    @Test func accentNeverLooksLikeAStatus() {
        let orange = tokens(0x1E1E2E, 0xCDD6F4, accent: NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1))
        #expect(orange.accent == orange.ramp(.chrome).secondary)
        let graphite = tokens(0x1E1E2E, 0xCDD6F4, accent: NSColor(white: 0.55, alpha: 1))
        #expect(graphite.accent == graphite.ramp(.chrome).secondary)
        let blue = tokens(0x1E1E2E, 0xCDD6F4)
        #expect(blue.accent != blue.ramp(.chrome).secondary)
        #expect(blue.onAccent == .black || blue.onAccent == .white)
    }

    @Test func increaseContrastRaisesTargets() {
        let normal = tokens(0x1E1E2E, 0xCDD6F4)
        let high = tokens(0x1E1E2E, 0xCDD6F4, contrast: true)
        #expect(cr(high.ramp(.chrome).secondary, high.chrome) >= 6.9)
        #expect(cr(high.ramp(.chrome).hairline, high.chrome) > cr(normal.ramp(.chrome).hairline, normal.chrome))
    }

    @Test func colorMathRoundTrips() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x1E1E2E, 0xFDF6E3, 0x4CC2FF] {
            let c = RGB(hex: hex)
            let (L, a, b) = ColorMath.oklab(c)
            #expect(ColorMath.fromOklab(L, a, b).hex == c.hex)
        }
        #expect(abs(ColorMath.contrast(RGB(0, 0, 0), RGB(1, 1, 1)) - 21) < 0.01)
    }

    @Test func themeUpdatePostsOnlyOnChange() {
        var posts = 0
        let obs = NotificationCenter.default.addObserver(forName: .corralThemeDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(obs) }
        Theme.update(background: RGB(hex: 0x101010).color, foreground: .white, windowTheme: nil)
        let after = posts
        Theme.update(background: RGB(hex: 0x101010).color, foreground: .white, windowTheme: nil)
        #expect(posts == after)
        #expect(posts >= 1 || Theme.tokens.chrome == ThemeTokens.make(background: RGB(hex: 0x101010).color, foreground: .white, windowTheme: nil, systemDark: true, increaseContrast: false, accent: .controlAccentColor).chrome)
    }

    @Test func keyHintsReadTheMenu() {
        let menu = NSMenu()
        let top = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let item = NSMenuItem(title: "Search", action: #selector(MainWindowController.searchSessions(_:)), keyEquivalent: "k")
        sub.addItem(item)
        top.submenu = sub
        menu.addItem(top)
        let saved = NSApplication.shared.mainMenu
        NSApplication.shared.mainMenu = menu
        defer { NSApplication.shared.mainMenu = saved }
        #expect(KeyHint.string(for: #selector(MainWindowController.searchSessions(_:))) == "⌘K")
        #expect(KeyHint.string(for: #selector(MainWindowController.nextAttention(_:))) == nil)
        #expect(KeyHint.format("c", [.command, .control]) == "⌃⌘C")
        #expect(KeyHint.format("\r", []) == "↩")
    }

    @Test func glyphCacheAndFonts() {
        let a = GlyphCache.image("sparkle", size: 11, colors: [.white])
        #expect(a != nil)
        #expect(GlyphCache.image("sparkle", size: 11, colors: [.white]) === a)
        #expect(GlyphCache.cgImage("questionmark.bubble.fill", size: 12, colors: [.black, .orange]) != nil)
        #expect(GlyphCache.image("definitely.not.a.symbol", size: 11, colors: [.white]) == nil)
        #expect(Fonts.sectionString("closed", color: .white).string == "CLOSED")
        #expect(GlyphCache.agentSymbol(.opencode) == "chevron.left.forwardslash.chevron.right")
    }
}
