import AppKit

/// A keyboard shortcut: a key code plus modifier flags, with a display form
/// like "⌘⇧R". Shared by Settings (storage), HotkeyManager (dispatch), the
/// menu (display), and the preferences picker (recording new combos).
struct KeyCombo: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "\u{2303}" }
        if modifiers.contains(.option) { symbols += "\u{2325}" }
        if modifiers.contains(.shift) { symbols += "\u{21e7}" }
        if modifiers.contains(.command) { symbols += "\u{2318}" }
        return symbols + Self.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "Key\(keyCode)"
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "Space", 36: "\u{21a9}", 48: "\u{21e5}", 51: "\u{232b}", 53: "\u{238b}",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}
