import Foundation

/// The CLDR plural categories. Which ones a language uses, and for which numbers, is `Language.pluralCategory(for:)`.
public enum PluralCategory: String, CaseIterable, Codable, Sendable {
    case zero, one, two, few, many, other
}

extension Language {
    /// The CLDR cardinal plural category of the whole number `n`. Counts in the interface are never fractional,
    /// so only the integer branches of each rule are written out.
    public func pluralCategory(for n: Int) -> PluralCategory {
        let i = n.magnitude
        let mod10 = i % 10, mod100 = i % 100
        let millions = i != 0 && i % 1_000_000 == 0
        switch self {
        case .id, .ja, .ko, .ms, .th, .vi, .zhHans, .zhHant:
            return .other
        case .en, .bg, .da, .de, .el, .fi, .hu, .nb, .nl, .sv, .ta, .tr:
            return i == 1 ? .one : .other
        case .es, .it, .ca, .ptPT:
            return i == 1 ? .one : millions ? .many : .other
        case .fr, .ptBR:
            return i <= 1 ? .one : millions ? .many : .other
        case .bn, .fa, .hi:
            return i <= 1 ? .one : .other
        case .fil:
            return [4, 6, 9].contains(mod10) ? .other : .one
        case .he:
            return i == 1 ? .one : i == 2 ? .two : .other
        case .ar:
            if i == 0 { return .zero }
            if i == 1 { return .one }
            if i == 2 { return .two }
            if (3...10).contains(mod100) { return .few }
            if (11...99).contains(mod100) { return .many }
            return .other
        case .cs, .sk:
            return i == 1 ? .one : (2...4).contains(i) ? .few : .other
        case .pl:
            if i == 1 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case .ru, .uk:
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .many
        case .hr, .sr:
            if mod10 == 1 && mod100 != 11 { return .one }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return .few }
            return .other
        case .ro:
            if i == 1 { return .one }
            if i == 0 || (1...19).contains(mod100) { return .few }
            return .other
        }
    }

    /// The categories a translation must spell out: every one a whole number can reach, plus `other`,
    /// which is always the fallback.
    public var requiredPluralCategories: Set<PluralCategory> {
        var seen: Set<PluralCategory> = [.other]
        for n in 0...1_000 { seen.insert(pluralCategory(for: n)) }
        for n in [1_000_000, 2_000_000, 10_000_000] { seen.insert(pluralCategory(for: n)) }
        return seen
    }
}
