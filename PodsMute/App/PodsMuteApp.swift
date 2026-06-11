//
//  PodsMuteApp.swift
//  PodsMute
//
//  Classic AppKit entry point. A SwiftUI `App` with only a `Settings` scene
//  did not reliably register the NSStatusItem in the menu bar (the app never
//  fully activated as an accessory). Driving NSApplication directly and
//  setting .accessory explicitly fixes that.
//

import Cocoa

@main
enum PodsMuteMain {

    // Retained for the lifetime of the process (NSApplication.delegate is weak).
    static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // Menu-bar-only app: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
