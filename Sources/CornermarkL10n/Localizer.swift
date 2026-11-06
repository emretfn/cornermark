import Foundation

/// One translated entry: a plain string, or one string per plural category.
public enum CatalogEntry: Equatable, Sendable {
    case text(String)
    case plural([PluralCategory: String])

    /// Reads one value of a catalog JSON object.
    public init?(json: Any) {
        if let s = json as? String { self = .text(s); return }
        guard let dict = json as? [String: String] else { return nil }
        var forms: [PluralCategory: String] = [:]
        for (k, v) in dict {
            guard let c = PluralCategory(rawValue: k) else { return nil }
            forms[c] = v
        }
        self = .plural(forms)
    }
}

/// A translation table keyed by the English source string. For a plural the key is the English `other` form.
public struct Catalog: Sendable {
    public let entries: [String: CatalogEntry]

    public init(entries: [String: CatalogEntry]) { self.entries = entries }

    public init(json: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        guard let dict = object as? [String: Any] else { throw CatalogError.notAnObject }
        var entries: [String: CatalogEntry] = [:]
        for (k, v) in dict {
            guard let entry = CatalogEntry(json: v) else { throw CatalogError.badEntry(k) }
            entries[k] = entry
        }
        self.entries = entries
    }

    public enum CatalogError: Error { case notAnObject, badEntry(String) }
}

/// The interface language for the whole process. It starts as English, so code that never chooses one
/// (the harnesses, the README renderer) reads English whatever the Mac's language is.
public enum L10n {
    /// Posted on the main thread after the language changes. Every window that shows text listens for it.
    public static let didChange = Notification.Name("CornermarkLanguageDidChange")

    private struct State {
        var language: Language = .en
        var locale = Locale(identifier: "en")
        var catalog = Catalog(entries: [:])
        var pseudo: ((String) -> String)?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()

    public static var language: Language { lock.withLock { state.language } }
    /// Formats dates and numbers. It follows the chosen language, and keeps the Mac's own region settings
    /// when the Mac already runs in that language.
    public static var locale: Locale { lock.withLock { state.locale } }
    public static var isRightToLeft: Bool { language.isRightToLeft }

    /// Switches the interface language. A no-op when nothing changes; otherwise posts `didChange`.
    public static func setLanguage(_ language: Language, current: Locale = .current) {
        apply(language, current: current, pseudo: nil)
    }

    /// For the harnesses: switches to `language` but renders every string, translated or not, through `transform`,
    /// so a check can tell a string that follows the language from one that was left hard-coded.
    public static func setPseudoLanguage(_ language: Language, transform: @escaping (String) -> String) {
        apply(language, current: Locale(identifier: "en_US_POSIX"), pseudo: transform)
    }

    private static func apply(_ language: Language, current: Locale, pseudo: ((String) -> String)?) {
        // The pseudo language keeps English number formatting so harness expectations stay put.
        let locale = pseudo != nil ? current : Language(preference: current.identifier) == language ? current : defaultLocale(for: language)
        let changed: Bool = lock.withLock {
            guard pseudo != nil || state.pseudo != nil || state.language != language || state.locale.identifier != locale.identifier else { return false }
            state = State(language: language, locale: locale, catalog: catalog(for: language), pseudo: pseudo)
            return true
        }
        guard changed else { return }
        let post = { NotificationCenter.default.post(name: didChange, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.sync(execute: post) }
    }

    /// The locale for a language the Mac does not already run in. Arabic's CLDR default writes Latin digits,
    /// but the Arabic catalog writes Arabic-Indic digits inside sentences, so both are made to agree.
    static func defaultLocale(for language: Language) -> Locale {
        Locale(identifier: language == .ar ? "ar@numbers=arab" : language.rawValue)
    }

    private static func catalog(for language: Language) -> Catalog {
        guard language != .en, let json = Catalogs.json[language.rawValue] else { return Catalog(entries: [:]) }
        do { return try Catalog(json: json) } catch {
            assertionFailure("catalog \(language.rawValue) unreadable: \(error)")
            return Catalog(entries: [:])
        }
    }

    static func lookup(_ key: String) -> (CatalogEntry?, Language, Locale) {
        lock.withLock {
            // The pseudo language renders the English through `transform`, never a catalog, so a harness check
            // reads the same text whatever the translations say.
            guard let pseudo = state.pseudo else { return (state.catalog.entries[key], state.language, state.locale) }
            return (.text(pseudo(key)), state.language, state.locale)
        }
    }

    /// Fills `{name}` placeholders. Numbers are written the way `locale` writes them.
    public static func fill(_ template: String, _ args: [String: Any], locale: Locale) -> String {
        guard !args.isEmpty, template.contains("{") else { return template }
        var out = template
        for (name, value) in args {
            out = out.replacingOccurrences(of: "{\(name)}", with: format(value, locale: locale))
        }
        return out
    }

    static func format(_ value: Any, locale: Locale) -> String {
        switch value {
        case let n as Int: return n.formatted(.number.locale(locale).grouping(.automatic))
        case let n as Double: return n.formatted(.number.locale(locale).precision(.fractionLength(0...2)))
        case let n as CGFloat: return Double(n).formatted(.number.locale(locale).precision(.fractionLength(0...2)))
        default: return String(describing: value)
        }
    }
}

/// The interface string for `english` in the current language. `english` must be a string literal so
/// `swift run L10nCheck` can find it; values go into `{name}` placeholders through `args`.
public func tr(_ english: String, _ args: [String: Any] = [:]) -> String {
    let (entry, _, locale) = L10n.lookup(english)
    guard case .text(let translated)? = entry else { return L10n.fill(english, args, locale: locale) }
    return L10n.fill(translated, args, locale: locale)
}

/// A counted string. `one` and `other` are the English forms; `{count}` is written in the current locale.
public func trPlural(one: String, other: String, count: Int, _ args: [String: Any] = [:]) -> String {
    let (entry, language, locale) = L10n.lookup(other)
    var all = args
    all["count"] = count
    switch entry {
    case .plural(let forms)?:
        let form = forms[language.pluralCategory(for: count)] ?? forms[.other] ?? other
        return L10n.fill(form, all, locale: locale)
    case .text(let pseudo)? where pseudo != other:
        let (oneEntry, _, _) = L10n.lookup(one)
        if count == 1, case .text(let pseudoOne)? = oneEntry { return L10n.fill(pseudoOne, all, locale: locale) }
        return L10n.fill(pseudo, all, locale: locale)
    default: break
    }
    return L10n.fill(count == 1 ? one : other, all, locale: locale)
}

/// A string to translate later, for tables built once and read after the language may have changed.
public struct LocalizedText: Hashable, Sendable {
    public let key: String
    public var text: String { tr(key) }
}

/// Marks `english` for translation without translating it yet. Read it with `.text`.
public func trKey(_ english: String) -> LocalizedText { LocalizedText(key: english) }
