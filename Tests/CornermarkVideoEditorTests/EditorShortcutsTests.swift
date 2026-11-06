import AppKit
import XCTest
@testable import CornermarkVideoEditor

final class EditorShortcutsTests: XCTestCase {
    func testEveryCommandHasExactlyOneEntryWithKeys() {
        for command in EditorCommand.allCases {
            let entries = EditorShortcuts.all.filter { $0.command == command }
            XCTAssertEqual(entries.count, 1, "\(command)")
            XCTAssertFalse(entries.first?.keys.isEmpty ?? true, "\(command)")
        }
    }

    /// The menu answers everywhere and the window hears a key before the focused timeline or zoom lane, so no key may mean two things
    /// to one view.
    func testNoKeyMeansTwoThingsWhereItIsHeard() {
        func reach(_ s: EditorShortcut) -> [EditorChord] {
            s.keys + (s.shiftForSecond ? s.keys.map { var c = $0; c.modifiers.insert(.shift); return c } : [])
        }
        for place in [EditorPlace.window, .timeline, .zoomLane] {
            let heard = EditorShortcuts.all.filter { $0.place == place || $0.place == .app || $0.place == .window }.flatMap(reach)
            XCTAssertEqual(heard.count, Set(heard).count, "\(place): \(heard.map(\.display))")
        }
    }

    func testEachKeyMatchesItsOwnCommandAndShiftMakesASecond() {
        for s in EditorShortcuts.all {
            for (i, key) in s.keys.enumerated() {
                XCTAssertEqual(EditorShortcuts.match(key, in: s.place), EditorKeyPress(command: s.command, keyIndex: i, bySecond: false), key.display)
                var shifted = key
                shifted.modifiers.insert(.shift)
                let press = EditorShortcuts.match(shifted, in: s.place)
                if s.shiftForSecond { XCTAssertEqual(press, EditorKeyPress(command: s.command, keyIndex: i, bySecond: true), shifted.display) }
            }
        }
    }

    func testAKeyEventReadsAsTheChordItCameFrom() throws {
        for s in EditorShortcuts.all {
            for key in s.keys {
                // Arrow keys arrive with the Fn and keypad flags set, which are not part of a chord.
                let flags = key.eventFlags.union(key.key == .left || key.key == .right ? [.function, .numericPad] : [])
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                                           characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key.keyCode))
                XCTAssertEqual(EditorChord(event: event), key, key.display)
            }
        }
    }

    func testKeysReadTheWayMacMenusWriteThem() {
        XCTAssertEqual(EditorShortcuts.shortcut(for: .exportFrame).keyText, "\u{21E7}\u{2318}E")
        XCTAssertEqual(EditorShortcuts.shortcut(for: .fullScreen).keyText, "\u{2303}\u{2318}F")
        XCTAssertEqual(EditorShortcuts.shortcut(for: .trimEnd).keyText, "\u{2325}\u{2318}\u{2190}  \u{2325}\u{2318}\u{2192}")
        XCTAssertEqual(EditorShortcuts.shortcut(for: .trimStart).note, "With the timeline focused. A frame a press, a second with Shift.")
        XCTAssertNil(EditorShortcuts.shortcut(for: .playPause).note)
        XCTAssertEqual(EditorShortcuts.shortcut(for: .trimEnd).keys[0].spoken, "Option Command Left Arrow")
    }

    func testOnlyLetterKeysBecomeMenuKeys() {
        let save = EditorShortcuts.shortcut(for: .saveAs).keys[0].menuKey
        XCTAssertEqual(save?.0, "s")
        XCTAssertEqual(save?.1, [.shift, .command])
        XCTAssertNil(EditorShortcuts.shortcut(for: .playPause).keys[0].menuKey)
    }
}
