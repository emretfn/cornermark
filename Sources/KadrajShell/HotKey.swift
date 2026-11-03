import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
struct HotKey: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let controlShift = UInt32(controlKey | shiftKey)

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    static func ctrlShift(_ keyCode: Int) -> HotKey { HotKey(keyCode: UInt32(keyCode), modifiers: controlShift) }

    init?(event: NSEvent) {
        let mods = Self.carbonModifiers(event.modifierFlags)
        guard mods != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return UInt32(m)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    var keyName: String { Self.keyNames[keyCode] ?? "Key \(keyCode)" }

    /// The character a menu item uses as key equivalent, when the key has one.
    var menuCharacter: String? {
        guard let name = Self.keyNames[keyCode], name.count == 1 else { return nil }
        return name.lowercased()
    }

    /// Mac order: control, option, shift, command.
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { s += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { s += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { s += "\u{2318}" }
        return s + keyName
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 49: "Space", 36: "\u{21A9}", 48: "\u{21E5}", 51: "\u{232B}",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        24: "=", 27: "-", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
    ]
}

enum HotKeyStatus: Equatable {
    case unassigned
    case registered
    case failed(String)
}

protocol HotKeyBackend: AnyObject {
    var onPressed: ((UInt32) -> Void)? { get set }
    /// Returns an OSStatus; `noErr` means the key is registered.
    func register(_ key: HotKey, id: UInt32) -> Int32
    func unregisterAll()
}

/// Carbon's RegisterEventHotKey: global, and needs no Accessibility permission.
final class CarbonHotKeyBackend: HotKeyBackend {
    var onPressed: ((UInt32) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4B44524A  // 'KDRJ'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard got == noErr else { return got }
            let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { backend.onPressed?(hotKeyID.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { Log.shell.error("InstallEventHandler failed: \(status)") }
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ key: HotKey, id: UInt32) -> Int32 {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
        return status
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
    }
}

/// Maps settings to registrations and remembers which ones failed, so Settings can say so.
@MainActor
final class HotKeyManager {
    private let backend: HotKeyBackend
    private let onAction: (ActionID) -> Void
    private(set) var status: [ActionID: HotKeyStatus] = [:]
    private var idsByNumber: [UInt32: ActionID] = [:]

    init(backend: HotKeyBackend, onAction: @escaping (ActionID) -> Void) {
        self.backend = backend
        self.onAction = onAction
        backend.onPressed = { [weak self] number in
            MainActor.assumeIsolated { if let id = self?.idsByNumber[number] { self?.onAction(id) } }
        }
    }

    func apply(_ settings: Settings) {
        backend.unregisterAll()
        status = [:]
        idsByNumber = [:]
        var taken: [HotKey: ActionID] = [:]
        for (index, spec) in ActionTable.specs.enumerated() {
            guard let key = settings.hotKey(for: spec.id) else { status[spec.id] = .unassigned; continue }
            if let other = taken[key] {
                status[spec.id] = .failed("Same shortcut as \(ActionTable.spec(other).title)")
                continue
            }
            taken[key] = spec.id
            let number = UInt32(index + 1)
            let code = backend.register(key, id: number)
            if code == noErr {
                idsByNumber[number] = spec.id
                status[spec.id] = .registered
            } else {
                status[spec.id] = .failed(Self.message(for: code))
            }
        }
    }

    var failures: [ActionID: String] {
        status.compactMapValues { if case .failed(let m) = $0 { return m } else { return nil } }
    }

    static func message(for code: Int32) -> String {
        code == Int32(eventHotKeyExistsErr)
            ? "Taken by another app or macOS"
            : "Registration failed (error \(code))"
    }
}
