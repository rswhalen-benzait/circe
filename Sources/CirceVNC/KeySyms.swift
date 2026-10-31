import AppKit

/// macOS virtual key code -> X11 keysym for keys that don't produce a printable character.
enum KeySyms {
    static let special: [UInt16: UInt32] = [
        0x24: 0xFF0D, // Return
        0x4C: 0xFF8D, // keypad Enter
        0x30: 0xFF09, // Tab
        0x31: 0x0020, // Space
        0x33: 0xFF08, // Delete (Backspace)
        0x75: 0xFFFF, // Forward Delete
        0x35: 0xFF1B, // Escape
        0x7B: 0xFF51, 0x7E: 0xFF52, 0x7C: 0xFF53, 0x7D: 0xFF54, // arrows
        0x73: 0xFF50, 0x77: 0xFF57, 0x74: 0xFF55, 0x79: 0xFF56, // Home End PgUp PgDn
        0x72: 0xFF6A, // Help/Insert
        0x7A: 0xFFBE, 0x78: 0xFFBF, 0x63: 0xFFC0, 0x76: 0xFFC1, 0x60: 0xFFC2, 0x61: 0xFFC3,
        0x62: 0xFFC4, 0x64: 0xFFC5, 0x65: 0xFFC6, 0x6D: 0xFFC7, 0x67: 0xFFC8, 0x6F: 0xFFC9,
        0x69: 0xFFCA, 0x6B: 0xFFCB, 0x71: 0xFFCC, 0x6A: 0xFFCD, 0x40: 0xFFCE, 0x4F: 0xFFCF, 0x50: 0xFFD0,
        0x47: 0xFF7F, // Clear / NumLock
    ]

    /// Modifier key codes -> keysym. ⌘ is Meta on Apple servers; elsewhere Control (so ⌘C/⌘V work on
    /// Linux) or Super, per the user's choice.
    static func modifier(_ code: UInt16, apple: Bool, command: CommandKeyMapping = .control) -> UInt32? {
        switch code {
        case 0x38: return 0xFFE1 // Shift_L
        case 0x3C: return 0xFFE2 // Shift_R
        case 0x3B: return 0xFFE3 // Control_L
        case 0x3E: return 0xFFE4 // Control_R
        case 0x3A: return 0xFFE9 // Alt_L (Option)
        case 0x3D: return 0xFFEA // Alt_R
        // ⌘ as Control uses Control_R so it never fights the physical Control key's up/down state.
        case 0x37: return apple ? 0xFFE7 : command == .control ? 0xFFE4 : 0xFFEB // Meta_L / Control_R / Super_L
        case 0x36: return apple ? 0xFFE8 : command == .control ? 0xFFE4 : 0xFFEC
        case 0x39: return 0xFFE5 // Caps Lock
        default: return nil
        }
    }

    static func modifierFlag(_ code: UInt16) -> NSEvent.ModifierFlags? {
        switch code {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        case 0x39: return .capsLock
        default: return nil
        }
    }

    static func keysym(for event: NSEvent) -> UInt32? {
        if let s = special[event.keyCode] { return s }
        // Characters as typed without Option/Control mangling but respecting Shift.
        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        guard let scalar = chars.unicodeScalars.first else { return nil }
        let v = scalar.value
        if v >= 0x20 && v <= 0x7E || v >= 0xA0 && v <= 0xFF { return v }
        if v >= 0xF700 { return nil } // private-use function keys not in table
        return 0x0100_0000 | v
    }
}
