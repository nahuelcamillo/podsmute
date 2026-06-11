//
//  AppSettings.swift
//  PodsMute
//
//  User-configurable preferences, persisted in UserDefaults. Centralized so
//  new options can be added in one place as the app grows toward a product.
//
//  Named AppSettings (not Settings) to avoid colliding with SwiftUI.Settings.
//

import Foundation

final class AppSettings {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let muteToneEnabled = "muteToneEnabled"
    }

    private init() {
        // Sensible defaults for a fresh install.
        defaults.register(defaults: [
            Keys.muteToneEnabled: true,
        ])
    }

    /// Whether to play our distinctive mute/unmute audio cue.
    var muteToneEnabled: Bool {
        get { defaults.bool(forKey: Keys.muteToneEnabled) }
        set { defaults.set(newValue, forKey: Keys.muteToneEnabled) }
    }
}
