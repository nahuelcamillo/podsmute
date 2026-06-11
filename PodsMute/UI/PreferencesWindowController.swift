//
//  PreferencesWindowController.swift
//  PodsMute
//
//  Preferences window: configurable keyboard shortcuts and the audio cue
//  toggle. Built programmatically (no xib). Because the app runs as an
//  accessory (no Dock icon), it temporarily becomes a regular app while the
//  window is open so it can receive keyboard focus for shortcut recording.
//

import Cocoa

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private let muteRecorder = ShortcutRecorderView(shortcut: AppSettings.shared.muteShortcut)
    private let soundRecorder = ShortcutRecorderView(shortcut: AppSettings.shared.toggleSoundShortcut)
    private let toneCheckbox = NSButton(checkboxWithTitle: "Play distinctive mute/unmute sound",
                                        target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "PodsMute Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Public

    func show() {
        // Become a regular app so the window can take keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Reflect current values in case they changed elsewhere.
        muteRecorder.setShortcut(AppSettings.shared.muteShortcut)
        soundRecorder.setShortcut(AppSettings.shared.toggleSoundShortcut)
        toneCheckbox.state = AppSettings.shared.muteToneEnabled ? .on : .off
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let shortcutsHeader = sectionLabel("Keyboard Shortcuts")
        let muteLabel = fieldLabel("Mute / Unmute:")
        let soundLabel = fieldLabel("Toggle sound on/off:")

        toneCheckbox.target = self
        toneCheckbox.action = #selector(toggleTone)

        muteRecorder.onChange = { AppSettings.shared.muteShortcut = $0 }
        soundRecorder.onChange = { AppSettings.shared.toggleSoundShortcut = $0 }

        // Keep the checkbox in sync if the tone is toggled elsewhere (menu/hotkey).
        NotificationCenter.default.addObserver(
            forName: .podsMuteToneEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toneCheckbox.state = AppSettings.shared.muteToneEnabled ? .on : .off
        }

        let grid = NSGridView(views: [
            [muteLabel, muteRecorder],
            [soundLabel, soundRecorder],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [shortcutsHeader, grid, NSBox.separator(), toneCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    // MARK: - Actions

    @objc private func toggleTone() {
        AppSettings.shared.muteToneEnabled = (toneCheckbox.state == .on)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Back to accessory: no Dock icon when prefs are closed.
        NSApp.setActivationPolicy(.accessory)
    }
}

private extension NSBox {
    /// A thin horizontal separator line for stacks.
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        return box
    }
}
