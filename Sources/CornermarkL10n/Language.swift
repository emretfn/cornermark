import Foundation

/// A language the interface is translated into. The raw value is the catalog name and the BCP 47 tag.
public enum Language: String, CaseIterable, Codable, Sendable {
    case en, ar, bg, bn, ca, cs, da, de, el, es, fa, fi, fil, fr, he, hi, hr, hu, id, it, ja, ko, ms, nb, nl, pl
    case ptBR = "pt-BR", ptPT = "pt-PT"
    case ro, ru, sk, sr, sv, ta, th, tr, uk, vi
    case zhHans = "zh-Hans", zhHant = "zh-Hant"

    /// The language's name for itself, shown in the picker so anyone can find their own.
    public var nativeName: String {
        switch self {
        case .en: return "English"
        case .ar: return "العربية"
        case .bg: return "Български"
        case .bn: return "বাংলা"
        case .ca: return "Català"
        case .cs: return "Čeština"
        case .da: return "Dansk"
        case .de: return "Deutsch"
        case .el: return "Ελληνικά"
        case .es: return "Español"
        case .fa: return "فارسی"
        case .fi: return "Suomi"
        case .fil: return "Filipino"
        case .fr: return "Français"
        case .he: return "עברית"
        case .hi: return "हिन्दी"
        case .hr: return "Hrvatski"
        case .hu: return "Magyar"
        case .id: return "Bahasa Indonesia"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .ms: return "Bahasa Melayu"
        case .nb: return "Norsk bokmål"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .ptBR: return "Português (Brasil)"
        case .ptPT: return "Português (Portugal)"
        case .ro: return "Română"
        case .ru: return "Русский"
        case .sk: return "Slovenčina"
        case .sr: return "Српски"
        case .sv: return "Svenska"
        case .ta: return "தமிழ்"
        case .th: return "ไทย"
        case .tr: return "Türkçe"
        case .uk: return "Українська"
        case .vi: return "Tiếng Việt"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }

    public var isRightToLeft: Bool { self == .ar || self == .he || self == .fa }

    /// Picks the first entry of `preferences` (most preferred first, as `Locale.preferredLanguages` lists them)
    /// that names a supported language, or English when none does.
    public static func resolve(preferences: [String]) -> Language {
        preferences.lazy.compactMap(Language.init(preference:)).first ?? .en
    }

    /// Maps one language tag such as `pt-PT`, `zh-Hant-TW`, `nb-NO` or `tr` to a supported language.
    public init?(preference tag: String) {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let code = parts.first?.lowercased() else { return nil }
        let script = parts.dropFirst().first { $0.count == 4 }?.capitalized
        let region = parts.dropFirst().first { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }?.uppercased()
        switch code {
        case "zh":
            let traditional = script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
            self = traditional ? .zhHant : .zhHans
        case "pt":
            // Brazil writes the unmarked form; every other Portuguese-speaking region follows the European norm.
            self = (region == nil || region == "BR") ? .ptBR : .ptPT
        case "no", "nb", "nn": self = .nb
        case "tl", "fil": self = .fil
        case "iw": self = .he
        case "in": self = .id
        default:
            guard let match = Language(rawValue: code) else { return nil }
            self = match
        }
    }
}
