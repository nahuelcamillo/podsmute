//
//  Shortcut.swift
//  PodsMute
//
//  A keyboard shortcut (key code + modifiers) with conversion between Cocoa
//  (NSEvent, used when recording) and Carbon (RegisterEventHotKey, used when
//  registering), plus a human-readable display string and persistence.
//

import Carbon.HIToolbox
import Cocoa

struct Shortcut: Equatable {

    /// Virtual key code (kVK_*). The same value is used by NSEvent and Carbon.
    let keyCode: UInt32
    /// Modifier mask in Carbon form (cmdKey | optionKey | ...).
    let carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Build from a recorded key-down event. Returns nil if no real key.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
        // Require at least one of cmd/option/control to avoid stealing plain keys.
        let needs = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard mods & needs != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = mods
    }

    // MARK: - Cocoa <-> Carbon modifiers

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        return c
    }

    // MARK: - Display

    /// e.g. "⌥⌘M". Modifier order matches Apple's convention (⌃⌥⇧⌘).
    var displayString: String {
        Shortcut.modifierString(carbonModifiers) + Shortcut.keyName(keyCode)
    }

    /// Just the modifier symbols (⌃⌥⇧⌘), in Apple's canonical order.
    static func modifierString(_ carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    // MARK: - Persistence

    var dictionary: [String: Int] {
        ["keyCode": Int(keyCode), "mods": Int(carbonModifiers)]
    }

    init?(dictionary: [String: Int]) {
        guard let k = dictionary["keyCode"], let m = dictionary["mods"] else { return nil }
        self.keyCode = UInt32(k)
        self.carbonModifiers = UInt32(m)
    }

    // MARK: - Key names

    /// Human-readable name for a virtual key code (common keys; falls back to a code).
    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[keyCode] { return special }
        if let ansi = ansiKeys[keyCode] { return ansi }
        return "Key\(keyCode)"
    }

    private static let ansiKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
    ]

    private static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
