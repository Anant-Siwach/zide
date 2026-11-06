import AppKit
import SwiftUI

enum TokenKind: UInt8, CaseIterable {
    case plain, keyword, type, function, string, number, comment, constant, attribute, property, tag, operatorSym, punctuation, variable, heading, link, escape, regex, macro
}

/// Editor + chrome colors. Dark is modelled on JetBrains' "Dark" (new UI), light on "Light".
struct Palette {
    let background, gutter, gutterText, gutterTextActive, currentLine, selection, text, cursor, bracket, indentGuide: NSColor
    let tokens: [TokenKind: NSColor]
    // chrome
    let chrome, chromeBorder, panel, tabActive, accent, error, warning, info, added, modified, untracked: NSColor

    func color(_ k: TokenKind) -> NSColor { tokens[k] ?? text }

    static func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static let dark = Palette(
        background: hex("1E1F22"), gutter: hex("1E1F22"), gutterText: hex("4B5059"), gutterTextActive: hex("A1A3AB"),
        currentLine: hex("26282E"), selection: hex("214283"), text: hex("BCBEC4"), cursor: hex("CED0D6"),
        bracket: hex("43454A"), indentGuide: hex("313438"),
        tokens: [
            .keyword: hex("CF8E6D"), .type: hex("6FAFBD"), .function: hex("56A8F5"), .string: hex("6AAB73"),
            .number: hex("2AACB8"), .comment: hex("7A7E85"), .constant: hex("C77DBB"), .attribute: hex("B3AE60"),
            .property: hex("C77DBB"), .tag: hex("D5B778"), .operatorSym: hex("BCBEC4"), .punctuation: hex("BCBEC4"),
            .variable: hex("BCBEC4"), .heading: hex("CF8E6D"), .link: hex("56A8F5"), .escape: hex("CF8E6D"),
            .regex: hex("42C3D4"), .macro: hex("B3AE60"),
        ],
        chrome: hex("2B2D30"), chromeBorder: hex("1E1F22"), panel: hex("2B2D30"), tabActive: hex("1E1F22"),
        accent: hex("3574F0"), error: hex("F75464"), warning: hex("E5C07B"), info: hex("6F9FFF"),
        added: hex("73BD79"), modified: hex("70AEFF"), untracked: hex("D1675A"))

    static let light = Palette(
        background: hex("FFFFFF"), gutter: hex("FFFFFF"), gutterText: hex("AEB3C2"), gutterTextActive: hex("767A8A"),
        currentLine: hex("F5F8FE"), selection: hex("A6D2FF"), text: hex("080808"), cursor: hex("000000"),
        bracket: hex("D7E6FF"), indentGuide: hex("EBECF0"),
        tokens: [
            .keyword: hex("0033B3"), .type: hex("008080"), .function: hex("00627A"), .string: hex("067D17"),
            .number: hex("1750EB"), .comment: hex("8C8C8C"), .constant: hex("871094"), .attribute: hex("9E880D"),
            .property: hex("871094"), .tag: hex("0033B3"), .operatorSym: hex("080808"), .punctuation: hex("080808"),
            .variable: hex("080808"), .heading: hex("0033B3"), .link: hex("006DCC"), .escape: hex("0037A6"),
            .regex: hex("264EFF"), .macro: hex("9E880D"),
        ],
        chrome: hex("F7F8FA"), chromeBorder: hex("EBECF0"), panel: hex("F7F8FA"), tabActive: hex("FFFFFF"),
        accent: hex("3574F0"), error: hex("E55765"), warning: hex("C29E4A"), info: hex("3574F0"),
        added: hex("5FB865"), modified: hex("3574F0"), untracked: hex("C7222D"))

    /// A full palette from a scheme's base colours (backgrounds derived by lightening/darkening the editor colour).
    static func scheme(dark: Bool, bg: String, chrome: String, text: String, comment: String, keyword: String, type: String,
                       function: String, string: String, number: String, constant: String, accent: String, selection: String) -> Palette {
        let b = hex(bg), t = hex(text)
        func mix(_ a: NSColor, _ c: NSColor, _ f: CGFloat) -> NSColor { a.blended(withFraction: f, of: c) ?? a }
        return Palette(
            background: b, gutter: b, gutterText: mix(b, t, 0.3), gutterTextActive: mix(b, t, 0.7),
            currentLine: mix(b, t, dark ? 0.05 : 0.04), selection: hex(selection), text: t, cursor: hex(accent),
            bracket: mix(b, t, dark ? 0.16 : 0.12), indentGuide: mix(b, t, dark ? 0.09 : 0.08),
            tokens: [
                .keyword: hex(keyword), .type: hex(type), .function: hex(function), .string: hex(string),
                .number: hex(number), .comment: hex(comment), .constant: hex(constant), .attribute: hex(type),
                .property: hex(constant), .tag: hex(keyword), .operatorSym: t, .punctuation: t, .variable: t,
                .heading: hex(keyword), .link: hex(function), .escape: hex(number), .regex: hex(string), .macro: hex(type),
            ],
            chrome: hex(chrome), chromeBorder: mix(hex(chrome), dark ? .black : .gray, dark ? 0.3 : 0.15), panel: hex(chrome), tabActive: b,
            accent: hex(accent), error: hex(dark ? "F7768E" : "D1242F"), warning: hex(dark ? "E0AF68" : "9A6700"), info: hex(accent),
            added: hex(dark ? "9ECE6A" : "1A7F37"), modified: hex(accent), untracked: hex(dark ? "F7768E" : "CF222E"))
    }

    static let oneDark = scheme(dark: true, bg: "282C34", chrome: "21252B", text: "ABB2BF", comment: "7F848E", keyword: "C678DD", type: "E5C07B",
                                function: "61AFEF", string: "98C379", number: "D19A66", constant: "D19A66", accent: "528BFF", selection: "3E4451")
    static let dracula = scheme(dark: true, bg: "282A36", chrome: "21222C", text: "F8F8F2", comment: "6272A4", keyword: "FF79C6", type: "8BE9FD",
                                function: "50FA7B", string: "F1FA8C", number: "BD93F9", constant: "BD93F9", accent: "BD93F9", selection: "44475A")
    static let nord = scheme(dark: true, bg: "2E3440", chrome: "272C36", text: "D8DEE9", comment: "616E88", keyword: "81A1C1", type: "8FBCBB",
                             function: "88C0D0", string: "A3BE8C", number: "B48EAD", constant: "B48EAD", accent: "88C0D0", selection: "434C5E")
    static let monokai = scheme(dark: true, bg: "272822", chrome: "1E1F1C", text: "F8F8F2", comment: "88846F", keyword: "F92672", type: "66D9EF",
                                function: "A6E22E", string: "E6DB74", number: "AE81FF", constant: "AE81FF", accent: "FD971F", selection: "49483E")
    static let githubLight = scheme(dark: false, bg: "FFFFFF", chrome: "F6F8FA", text: "1F2328", comment: "6E7781", keyword: "CF222E", type: "953800",
                                    function: "8250DF", string: "0A3069", number: "0550AE", constant: "0550AE", accent: "0969DA", selection: "B6E3FF")
    static let solarizedLight = scheme(dark: false, bg: "FDF6E3", chrome: "EEE8D5", text: "586E75", comment: "93A1A1", keyword: "859900", type: "B58900",
                                       function: "268BD2", string: "2AA198", number: "D33682", constant: "6C71C4", accent: "268BD2", selection: "E4DCC4")
}

enum Theme {
    static let changed = Notification.Name("ZideThemeChanged")

    static var isDark: Bool {
        Prefs.shared.theme.isDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    static var current: Palette {
        switch Prefs.shared.theme {
        case .oneDark: .oneDark
        case .dracula: .dracula
        case .nord: .nord
        case .monokai: .monokai
        case .githubLight: .githubLight
        case .solarizedLight: .solarizedLight
        default: isDark ? .dark : .light
        }
    }

    static func update() {
        NSApp.appearance = Prefs.shared.theme.isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

extension NSColor { var swiftUI: Color { Color(nsColor: self) } }

/// SwiftUI access to the palette that refreshes on theme changes.
final class ThemeObserver: ObservableObject {
    static let shared = ThemeObserver()
    @Published var palette = Theme.current
    private var observers: [Any] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            self?.palette = Theme.current
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Theme.update() }
        })
    }
}
