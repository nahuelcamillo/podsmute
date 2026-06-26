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
    /// Posted when the mute-tone preference changes, so every UI that shows it
    /// (menu item, Preferences checkbox) can stay in sync.
    static let podsMuteToneEnabledChanged = Notification.Name("PodsMuteToneEnabledChanged")
    /// Posted when the stealth-mute preference changes, so the bridge can be
    /// brought up/down immediately if a call is already running.
    static let podsMuteStealthModeChanged = Notification.Name("PodsMuteStealthModeChanged")
    /// Posted when a deferred AudioBridge start finally succeeds (the input
    /// device was not ready at call start), so MuteCoordinator can reconcile
    /// the stealth state and re-apply the current mute.
    static let podsMuteBridgeDidStart = Notification.Name("PodsMuteBridgeDidStart")
}

final class AppSettings {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let muteToneEnabled = "muteToneEnabled"
        static let muteShortcut = "muteShortcut"
        static let toggleSoundShortcut = "toggleSoundShortcut"
        static let bannerKillerEnabled = "bannerKillerEnabled"
        static let toneVolume = "toneVolume"
        static let stealthMuteEnabled = "stealthMuteEnabled"
    }

    /// Default cue volume (0...1). ~0.44 reproduces the validated loudness.
    static let defaultToneVolume = 0.44

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
            Keys.bannerKillerEnabled: true,
            Keys.toneVolume: Self.defaultToneVolume,
            Keys.stealthMuteEnabled: true,
        ])
    }

    /// Whether to bridge the mic into BlackHole during calls so muting is
    /// undetectable by meeting apps. A no-op until BlackHole is installed.
    var stealthMuteEnabled: Bool {
        get { defaults.bool(forKey: Keys.stealthMuteEnabled) }
        set {
            guard newValue != stealthMuteEnabled else { return }
            defaults.set(newValue, forKey: Keys.stealthMuteEnabled)
            NotificationCenter.default.post(name: .podsMuteStealthModeChanged, object: nil)
        }
    }

    /// Whether to hide the system "Microphone On/Off" banner (needs Accessibility).
    var bannerKillerEnabled: Bool {
        get { defaults.bool(forKey: Keys.bannerKillerEnabled) }
        set { defaults.set(newValue, forKey: Keys.bannerKillerEnabled) }
    }

    /// Volume of the audio cue (0...1).
    var toneVolume: Double {
        get { defaults.double(forKey: Keys.toneVolume) }
        set { defaults.set(min(1, max(0, newValue)), forKey: Keys.toneVolume) }
    }

    /// Whether to play our distinctive mute/unmute audio cue.
    var muteToneEnabled: Bool {
        get { defaults.bool(forKey: Keys.muteToneEnabled) }
        set {
            guard newValue != muteToneEnabled else { return }
            defaults.set(newValue, forKey: Keys.muteToneEnabled)
            NotificationCenter.default.post(name: .podsMuteToneEnabledChanged, object: nil)
        }
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
