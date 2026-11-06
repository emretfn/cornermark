import XCTest
@testable import CornermarkL10n

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.setLanguage(.en) }

    func testSystemPreferencePicksFirstSupportedLanguage() {
        XCTAssertEqual(Language.resolve(preferences: ["xx-YY", "tr-TR", "de-DE"]), .tr)
        XCTAssertEqual(Language.resolve(preferences: ["kl", "eu"]), .en)
        XCTAssertEqual(Language.resolve(preferences: []), .en)
        XCTAssertEqual(Language.resolve(preferences: ["zh-Hant-TW"]), .zhHant)
        XCTAssertEqual(Language.resolve(preferences: ["zh-HK"]), .zhHant)
        XCTAssertEqual(Language.resolve(preferences: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(Language.resolve(preferences: ["pt"]), .ptBR)
        XCTAssertEqual(Language.resolve(preferences: ["pt-PT"]), .ptPT)
        XCTAssertEqual(Language.resolve(preferences: ["pt-AO"]), .ptPT)
        XCTAssertEqual(Language.resolve(preferences: ["no-NO"]), .nb)
        XCTAssertEqual(Language.resolve(preferences: ["en-GB"]), .en)
        XCTAssertEqual(Language.resolve(preferences: ["sr-Latn-RS"]), .sr)
    }

    func testPluralCategoriesFollowCLDR() {
        func cats(_ l: Language, _ ns: [Int]) -> [String] { ns.map { l.pluralCategory(for: $0).rawValue } }
        XCTAssertEqual(cats(.en, [0, 1, 2]), ["other", "one", "other"])
        XCTAssertEqual(cats(.fr, [0, 1, 2, 1_000_000]), ["one", "one", "other", "many"])
        XCTAssertEqual(cats(.ar, [0, 1, 2, 3, 10, 11, 99, 100, 102, 103, 111]), ["zero", "one", "two", "few", "few", "many", "many", "other", "other", "few", "many"])
        XCTAssertEqual(cats(.ru, [1, 2, 5, 11, 21, 22, 25, 111]), ["one", "few", "many", "many", "one", "few", "many", "many"])
        XCTAssertEqual(cats(.pl, [1, 2, 5, 12, 22, 25]), ["one", "few", "many", "many", "few", "many"])
        XCTAssertEqual(cats(.cs, [1, 3, 5]), ["one", "few", "other"])
        XCTAssertEqual(cats(.he, [1, 2, 3, 20]), ["one", "two", "other", "other"])
        XCTAssertEqual(cats(.ro, [0, 1, 2, 19, 20, 101]), ["few", "one", "few", "few", "other", "few"])
        XCTAssertEqual(cats(.fil, [1, 4, 5, 6, 9, 10]), ["one", "other", "one", "other", "other", "one"])
        XCTAssertEqual(cats(.hi, [0, 1, 2]), ["one", "one", "other"])
        XCTAssertEqual(cats(.ja, [0, 1, 2]), ["other", "other", "other"])
        XCTAssertEqual(Language.ar.requiredPluralCategories, Set(PluralCategory.allCases))
        XCTAssertEqual(Language.ja.requiredPluralCategories, [.other])
        XCTAssertEqual(Language.pl.requiredPluralCategories, [.one, .few, .many, .other])
    }

    func testEnglishNeedsNoCatalog() {
        L10n.setLanguage(.en)
        XCTAssertEqual(tr("Version {version}.", ["version": "1.2"]), "Version 1.2.")
        XCTAssertEqual(trPlural(one: "{count} day", other: "{count} days", count: 1), "1 day")
        XCTAssertEqual(trPlural(one: "{count} day", other: "{count} days", count: 1_200), "1,200 days")
    }

    func testChangingLanguagePostsOnce() {
        L10n.setLanguage(.en)
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: L10n.didChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        L10n.setLanguage(.de, current: Locale(identifier: "en_US"))
        L10n.setLanguage(.de, current: Locale(identifier: "en_US"))
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(L10n.locale.identifier, "de")
        XCTAssertEqual(trPlural(one: "{count} day", other: "{count} days", count: 1_200).filter(\.isNumber), "1200")
        XCTAssertTrue(trPlural(one: "{count} day", other: "{count} days", count: 1_200).hasPrefix("1.200"))
    }

    func testMacRegionIsKeptWhenItSpeaksTheChosenLanguage() {
        L10n.setLanguage(.de, current: Locale(identifier: "de_CH"))
        XCTAssertEqual(L10n.locale.identifier, "de_CH")
        L10n.setLanguage(.ar, current: Locale(identifier: "de_CH"))
        XCTAssertEqual(L10n.locale.identifier, "ar")
        XCTAssertTrue(L10n.isRightToLeft)
    }

    func testCatalogParsesPluralForms() throws {
        let c = try Catalog(json: #"{"Save": "Kaydet", "{count} days": {"one": "{count} gün", "other": "{count} gün"}}"#)
        XCTAssertEqual(c.entries["Save"], .text("Kaydet"))
        XCTAssertEqual(c.entries["{count} days"], .plural([.one: "{count} gün", .other: "{count} gün"]))
        XCTAssertThrowsError(try Catalog(json: #"{"x": {"several": "y"}}"#))
    }
}
