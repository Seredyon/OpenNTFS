import Foundation
import SwiftUI

/// Interface languages. English is the development language and the default;
/// every other language lives in `<code>.lproj/Localizable.strings` keyed by the English text.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case russian = "ru"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .russian: return "Русский"
        }
    }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "ru_RU") }
}

enum Localizer {
    static let languageKey = "InterfaceLanguage"
    private(set) static var language: AppLanguage =
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .english
    private static var bundles: [AppLanguage: Bundle] = [:]
    /// The language AppKit was started with (system menus and panels keep it until relaunch).
    private(set) static var launchLanguage: AppLanguage = .english

    private static func bundle(for language: AppLanguage) -> Bundle? {
        if let cached = bundles[language] { return cached }
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        bundles[language] = bundle
        return bundle
    }

    static func string(_ key: String) -> String {
        guard language != .english, let bundle = bundle(for: language) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Called before any window exists so AppKit-provided menus and panels use the same
    /// language as the app (the same per-app key System Settings › Language writes).
    static func prepareAtLaunch() {
        launchLanguage = language
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }

    static func select(_ newValue: AppLanguage) {
        language = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
        UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
    }
}

/// Localized text for an English key.
func L(_ key: String) -> String { Localizer.string(key) }

/// Marks an English key that is translated later through `L(variable)`; returns it unchanged.
func LK(_ key: String) -> String { key }

/// Localized format string (keys use %@ and %ld placeholders).
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Localizer.string(key), locale: Localizer.language.locale, arguments: arguments)
}

/// Pluralized text. The English forms are given inline; a translation stores its forms in the
/// value for the plural key separated by "|" (Russian: one|few|many).
func LP(_ count: Int, _ singular: String, _ plural: String) -> String {
    let template: String
    switch Localizer.language {
    case .english:
        template = count == 1 ? singular : plural
    case .russian:
        let forms = Localizer.string(plural).components(separatedBy: "|")
        if forms.count == 3 {
            let n = abs(count) % 100, d = n % 10
            template = (d == 1 && n != 11) ? forms[0] : ((2...4).contains(d) && !(12...14).contains(n)) ? forms[1] : forms[2]
        } else {
            template = forms.first ?? plural
        }
    }
    return String(format: template, locale: Localizer.language.locale, count)
}

enum DoubleClickAction: String, CaseIterable, Identifiable {
    case menu, open, quickLook
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menu: return L("Show actions menu")
        case .open: return L("Open with default app")
        case .quickLook: return L("Quick Look")
        }
    }
}

/// User preferences stored in the app's standard preferences domain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var language: AppLanguage = Localizer.language {
        didSet { if language != Localizer.language { Localizer.select(language) } }
    }
    @Published var showHiddenItems: Bool {
        didSet { defaults.set(showHiddenItems, forKey: "ShowHiddenItems") }
    }
    @Published var skipMacMetadata: Bool {
        didSet { defaults.set(skipMacMetadata, forKey: "SkipMacMetadata") }
    }
    @Published var doubleClickAction: DoubleClickAction {
        didSet { defaults.set(doubleClickAction.rawValue, forKey: "DoubleClickAction") }
    }

    private init() {
        showHiddenItems = defaults.object(forKey: "ShowHiddenItems") as? Bool ?? false
        skipMacMetadata = defaults.object(forKey: "SkipMacMetadata") as? Bool ?? true
        doubleClickAction = DoubleClickAction(rawValue: defaults.string(forKey: "DoubleClickAction") ?? "") ?? .menu
    }
}

/// Converts worker and engine messages (always English) into the interface language.
enum ErrorText {
    private static let ufsdCodes: [String: String] = [
        "0xa0001023": LK("There is not enough free space on the NTFS volume."),
        "0xa000100f": LK("A file or folder with this name already exists"),
        "0xa000100e": LK("The file or folder was not found."),
        "0xa0001007": LK("The NTFS engine ran out of memory."),
        "0xa000102b": LK("The NTFS journal could not be replayed. Connect the drive to Windows and run a disk check."),
    ]

    static func localize(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: ": UFSD ") {
            let operation = String(text[..<range.lowerBound])
            let code = String(text[range.upperBound...]).lowercased()
            if let known = ufsdCodes[code] { return L(known) }
            return L("NTFS engine error during “%@” (%@).", L(operation), code)
        }
        if text.hasPrefix("NTFS volume flags "), text.hasSuffix(" require further checking before writing") {
            let flags = text.dropFirst("NTFS volume flags ".count).prefix(while: { $0 != " " })
            return L("The NTFS volume state (flags %@) needs to be checked on Windows before writing.", String(flags))
        }
        return L(text)
    }
}
