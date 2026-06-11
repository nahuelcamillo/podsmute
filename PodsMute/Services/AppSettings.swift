//
//  AppSettings.swift
//  PodsMute
//
//  User-configurable preferences, persisted in UserDefaults. Centralized so
//  new options can be added in one place as the app grows toward a product.
//
//  Named AppSettings (not Settings) to avoid colliding with SwiftUI.Settings.
//

import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    /// Posted when a configurable shortcut changes, so hotkeys can re-register.
    static let podsMuteShortcutsChanged = Notification.Name("PodsMuteShortcutsChanged")
}

final class AppSettings {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let muteToneEnabled = "muteToneEnabled"
        static let muteShortcut = "muteShortcut"
        static let toggleSoundShortcut = "toggleSoundShortcut"
    }

    // Factory defaults match the previously hardcoded combos.
    static let defaultMuteShortcut = Shortcut(keyCode: 46, // M
                                              carbonModifiers: UInt32(optionKey | cmdKey))
    static let defaultToggleSoundShortcut = Shortcut(keyCode: 1, // S
                                                     carbonModifiers: UInt32(optionKey | cmdKey))

    private init() {
        defaults.register(defaults: [
            Keys.muteToneEnabled: true,
            Keys.muteShortcut: Self.defaultMuteShortcut.dictionary,
            Keys.toggleSoundShortcut: Self.defaultToggleSoundShortcut.dictionary,
        ])
    }

    /// Whether to play our distinctive mute/unmute audio cue.
    var muteToneEnabled: Bool {
        get { defaults.bool(forKey: Keys.muteToneEnabled) }
        set { defaults.set(newValue, forKey: Keys.muteToneEnabled) }
    }

    /// Shortcut to toggle mute. nil means "no shortcut assigned".
    var muteShortcut: Shortcut? {
        get { shortcut(forKey: Keys.muteShortcut) }
        set { setShortcut(newValue, forKey: Keys.muteShortcut) }
    }

    /// Shortcut to toggle the audio cue. nil means "no shortcut assigned".
    var toggleSoundShortcut: Shortcut? {
        get { shortcut(forKey: Keys.toggleSoundShortcut) }
        set { setShortcut(newValue, forKey: Keys.toggleSoundShortcut) }
    }

    // MARK: - Shortcut storage helpers

    private func shortcut(forKey key: String) -> Shortcut? {
        guard let dict = defaults.dictionary(forKey: key) as? [String: Int] else { return nil }
        return Shortcut(dictionary: dict)
    }

    private func setShortcut(_ shortcut: Shortcut?, forKey key: String) {
        if let shortcut = shortcut {
            defaults.set(shortcut.dictionary, forKey: key)
        } else {
            // Store an empty dict to mean "explicitly cleared" (overrides default).
            defaults.set([String: Int](), forKey: key)
        }
        NotificationCenter.default.post(name: .podsMuteShortcutsChanged, object: nil)
    }
}
