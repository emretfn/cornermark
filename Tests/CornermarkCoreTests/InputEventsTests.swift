import XCTest
@testable import CornermarkCore

final class InputEventsTests: XCTestCase {
    private let shown = ClickHighlight(isVisible: true)
    private let keysShown = KeystrokeDisplay(isVisible: true, keys: .all)

    private func state(clicks: [ClickEvent] = [], keys: [KeyEvent] = [], highlight: ClickHighlight? = nil, keystrokes: KeystrokeDisplay? = nil, at t: Double) -> InputOverlayState {
        InputOverlay.state(clicks: clicks, keys: keys, highlight: highlight ?? shown, keystrokes: keystrokes ?? keysShown, at: t)
    }

    func testShortcutShowsEveryModifierAndTheBaseKey() {
        let k = KeyLabel.make(keyCode: 21, base: "4", typed: "$", modifiers: [.shift, .command])
        XCTAssertEqual(k?.label, "\u{21E7}\u{2318}4")
        XCTAssertEqual(k?.isCommand, true)
        XCTAssertEqual(KeyLabel.make(keyCode: 0, base: "a", typed: "\u{01}", modifiers: [.control, .option])?.label, "\u{2303}\u{2325}A")
    }

    func testTypingShowsWhatWasTypedAndOptionAloneIsNotAShortcut() {
        XCTAssertEqual(KeyLabel.make(keyCode: 0, base: "a", typed: "A", modifiers: [.shift]), KeyEvent(t: 0, label: "A", isCommand: false))
        XCTAssertEqual(KeyLabel.make(keyCode: 12, base: "q", typed: "@", modifiers: [.option]), KeyEvent(t: 0, label: "@", isCommand: false))
        XCTAssertEqual(KeyLabel.make(keyCode: 36, base: "\r", typed: "\r", modifiers: [])?.label, "\u{21A9}")
        XCTAssertEqual(KeyLabel.make(keyCode: 49, base: " ", typed: " ", modifiers: [.command])?.label, "\u{2318}\u{2423}")
        XCTAssertNil(KeyLabel.make(keyCode: 32, base: "u", typed: "", modifiers: [.option]), "a dead key shows nothing")
    }

    func testShortcutsOnlyKeepsCommandAndControl() {
        let capture = InputCapture(clicks: false, keys: .shortcuts)
        XCTAssertTrue(capture.admitsKey(isCommand: true))
        XCTAssertFalse(capture.admitsKey(isCommand: false))
        XCTAssertFalse(InputCapture(clicks: true).admitsKey(isCommand: true), "keys are not watched unless shown")
        XCTAssertTrue(InputCapture().isEmpty)
    }

    func testRingLivesFourTenthsOfASecondAndGrowsThenFades() {
        let click = [ClickEvent(t: 1, x: 50, y: 60)]
        XCTAssertTrue(state(clicks: click, at: 0.99).rings.isEmpty)
        let first = state(clicks: click, at: 1).rings.first
        XCTAssertEqual(first?.radius ?? 0, 12, accuracy: 0.001, "starts at 60% of the medium radius")
        XCTAssertEqual(first?.opacity, 1)
        let late = state(clicks: click, at: 1.3).rings.first
        XCTAssertEqual(late?.radius ?? 0, 20, accuracy: 0.001)
        XCTAssertLessThan(late?.opacity ?? 1, 0.6)
        XCTAssertTrue(state(clicks: click, at: 1.41).rings.isEmpty, "gone after 0.4 s")
    }

    func testStillRingKeepsItsSizeAndOpacity() {
        var still = shown
        still.animates = false
        still.size = .large
        let r = state(clicks: [ClickEvent(t: 0, x: 1, y: 1)], highlight: still, at: 0.35).rings.first
        XCTAssertEqual(r, ClickRing(x: 1, y: 1, radius: 28, opacity: 1))
    }

    func testBadgeEntersHoldsThenFades() {
        let keys = [KeyEvent(t: 2, label: "\u{2318}S", isCommand: true)]
        let entering = state(keys: keys, at: 2.05).badge
        XCTAssertEqual(entering?.text, "\u{2318}S")
        XCTAssertLessThan(entering?.scale ?? 1, 1)
        XCTAssertGreaterThanOrEqual(entering?.scale ?? 0, 0.9)
        XCTAssertEqual(state(keys: keys, at: 3.5).badge?.opacity, 1)
        XCTAssertEqual(state(keys: keys, at: 3.5).badge?.scale, 1)
        XCTAssertEqual(state(keys: keys, at: 3.7).badge?.opacity ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(state(keys: keys, at: 3.81).badge)
    }

    func testTypedKeysJoinOneBadgeAndAShortcutStartsANewOne() {
        let keys = [KeyEvent(t: 0, label: "h", isCommand: false), KeyEvent(t: 0.2, label: "i", isCommand: false),
                    KeyEvent(t: 1, label: "\u{2318}A", isCommand: true), KeyEvent(t: 1.2, label: "x", isCommand: false)]
        XCTAssertEqual(state(keys: keys, at: 0.1).badge?.text, "h", "a key shows from its own moment")
        XCTAssertEqual(state(keys: keys, at: 0.5).badge?.text, "hi")
        XCTAssertEqual(state(keys: keys, at: 1.1).badge?.text, "\u{2318}A")
        XCTAssertEqual(state(keys: keys, at: 1.3).badge?.text, "x")
        var shortcuts = keysShown
        shortcuts.keys = .shortcuts
        XCTAssertNil(state(keys: Array(keys.prefix(2)), keystrokes: shortcuts, at: 0.5).badge, "Shortcuts only hides typing")
        XCTAssertEqual(state(keys: keys, keystrokes: shortcuts, at: 1.3).badge?.text, "\u{2318}A")
    }

    func testLongTypingKeepsTheNewestCharacters() {
        let keys = (0..<30).map { KeyEvent(t: Double($0) * 0.1, label: String(UnicodeScalar(97 + $0 % 26)!), isCommand: false) }
        let text = state(keys: keys, at: 3).badge?.text ?? ""
        XCTAssertEqual(text.count, KeystrokeDisplay.maxCharacters)
        XCTAssertTrue(text.hasSuffix("abcd"))
    }

    func testHiddenMarksDrawNothing() {
        let s = InputOverlay.state(clicks: [ClickEvent(t: 0, x: 0, y: 0)], keys: [KeyEvent(t: 0, label: "a", isCommand: false)],
                                   highlight: ClickHighlight(), keystrokes: KeystrokeDisplay(), at: 0.1)
        XCTAssertTrue(s.isEmpty)
    }

    func testProjectKeepsClicksKeysAndTheirSettings() throws {
        var p = RecordingProject(events: .init(clicks: [ClickEvent(t: 2, x: 1, y: 1), ClickEvent(t: 1, x: 2, y: 2)],
                                               keys: [KeyEvent(t: 1, label: "\u{2318}C", isCommand: true)]))
        p.edits.clicks = ClickHighlight(isVisible: true, color: .red, style: .filled, size: .large, animates: false)
        p.edits.keystrokes = KeystrokeDisplay(isVisible: true, keys: .all, position: .topCenter, size: .small, theme: .light)
        let back = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.events.clicks.map(\.t), [1, 2])
        XCTAssertEqual(back.inputOverlay(at: 1.1).badge?.text, "\u{2318}C")
    }

    func testOlderProjectsAndDamagedEntriesStillOpen() throws {
        let old = try JSONDecoder().decode(RecordingProject.self, from: Data(#"{"events": {"pointer": []}, "edits": {"cursor": {"scale": 2}}}"#.utf8))
        XCTAssertEqual(old.events.clicks, [])
        XCTAssertEqual(old.edits.clicks, ClickHighlight())
        XCTAssertEqual(old.edits.keystrokes, KeystrokeDisplay())
        let damaged = try JSONDecoder().decode(RecordingProject.self, from: Data("""
        {"events": {"clicks": [{"t": 1, "x": 1, "y": 1}, {"t": "x"}], "keys": [{"t": 1, "label": "a"}, {"t": 2, "label": "b", "isCommand": false}]},
         "edits": {"clicks": {"color": "purple", "isVisible": true}, "keystrokes": {"position": "middle", "theme": "light"}}}
        """.utf8))
        XCTAssertEqual(damaged.events.clicks.count, 1)
        XCTAssertEqual(damaged.events.keys.map(\.label), ["b"])
        XCTAssertEqual(damaged.edits.clicks, ClickHighlight(isVisible: true), "an unknown color falls back alone")
        XCTAssertEqual(damaged.edits.keystrokes.theme, .light)
        XCTAssertEqual(damaged.edits.keystrokes.position, .bottomCenter)
    }
}
