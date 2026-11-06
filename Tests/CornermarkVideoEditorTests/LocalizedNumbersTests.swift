import CornermarkL10n
import XCTest
@testable import CornermarkVideoEditor

final class LocalizedNumbersTests: XCTestCase {
    override func tearDown() { L10n.setLanguage(.en) }

    func testTimeCodesKeepTheirShapeAndTakeTheLanguagesDigits() {
        L10n.setLanguage(.en)
        XCTAssertEqual(Timecode.text(61.5), "1:01.50")
        L10n.setLanguage(.fa, current: Locale(identifier: "en_US"))
        XCTAssertEqual(Timecode.text(61.5), "\u{06F1}:\u{06F0}\u{06F1}.\u{06F5}\u{06F0}")
        XCTAssertEqual(Timecode.label(5, step: 5), "\u{06F0}:\u{06F0}\u{06F5}")
    }

    func testTypedNumbersAreReadInAnyScript() {
        XCTAssertEqual(Digits.parse("1920"), 1920)
        XCTAssertEqual(Digits.parse("\u{06F1}\u{06F9}\u{06F2}\u{06F0}"), 1920)
        XCTAssertEqual(Digits.parse("\u{0661}\u{0662}"), 12)
        XCTAssertNil(Digits.parse("12x"))
    }

    func testEnglishNumbersAreUnchanged() {
        L10n.setLanguage(.en)
        XCTAssertEqual(Digits.percent(1.5), "150%")
        XCTAssertEqual(Digits.fixed(0.5, 2), "0.50")
        XCTAssertEqual(Digits.text(1920), "1920")
        XCTAssertEqual(ExportPanel.bytes(1_234_567), "1.2 MB")
    }

    func testShortcutTitlesFollowTheLanguage() {
        L10n.setLanguage(.en)
        XCTAssertEqual(EditorCommand.playPause.title, "Play or Pause")
        L10n.setPseudoLanguage(.ar) { "\u{2039}\($0)\u{203A}" }
        XCTAssertEqual(EditorCommand.playPause.title, "\u{2039}Play or Pause\u{203A}")
        XCTAssertEqual(EditorSection.motionBlur.title, "\u{2039}Motion Blur\u{203A}")
    }
}
