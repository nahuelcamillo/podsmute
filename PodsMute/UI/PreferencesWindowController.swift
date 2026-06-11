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
    private let volumeSlider = NSSlider(value: AppSettings.shared.toneVolume,
                                        minValue: 0, maxValue: 1,
                                        target: nil, action: nil)
    private let bannerCheckbox = NSButton(checkboxWithTitle: "Hide system mute banner during screen share",
                                          target: nil, action: nil)
    private let volumeRow = NSStackView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
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
        volumeSlider.doubleValue = AppSettings.shared.toneVolume
        bannerCheckbox.state = AppSettings.shared.bannerKillerEnabled ? .on : .off
        updateVolumeEnabled()
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

        bannerCheckbox.target = self
        bannerCheckbox.action = #selector(toggleBanner)

        // Fire the action only when the drag ends, then preview the new volume.
        volumeSlider.isContinuous = false
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        muteRecorder.onChange = { AppSettings.shared.muteShortcut = $0 }
        soundRecorder.onChange = { AppSettings.shared.toggleSoundShortcut = $0 }

        // Keep the checkbox + volume enablement in sync if toggled elsewhere.
        NotificationCenter.default.addObserver(
            forName: .podsMuteToneEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toneCheckbox.state = AppSettings.shared.muteToneEnabled ? .on : .off
            self?.updateVolumeEnabled()
        }

        let grid = NSGridView(views: [
            [muteLabel, muteRecorder],
            [soundLabel, soundRecorder],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        // Volume row: speaker icons flank the slider; indented under the checkbox.
        let lowIcon = volumeIcon("speaker.fill")
        let highIcon = volumeIcon("speaker.wave.3.fill")
        volumeRow.orientation = .horizontal
        volumeRow.spacing = 8
        volumeRow.alignment = .centerY
        volumeRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        volumeRow.setViews([lowIcon, volumeSlider, highIcon], in: .leading)

        let stack = NSStackView(views: [
            shortcutsHeader, grid,
            NSBox.separator(),
            sectionLabel("Audio Cue"), toneCheckbox, volumeRow,
            NSBox.separator(),
            sectionLabel("System Banner"), bannerCheckbox,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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

    private func volumeIcon(_ symbol: String) -> NSImageView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let iv = NSImageView(image: image ?? NSImage())
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iv.contentTintColor = .secondaryLabelColor
        return iv
    }

    /// Enable/dim the volume row to reflect whether the cue is on.
    private func updateVolumeEnabled() {
        let enabled = AppSettings.shared.muteToneEnabled
        volumeSlider.isEnabled = enabled
        volumeRow.alphaValue = enabled ? 1.0 : 0.4
    }

    // MARK: - Actions

    @objc private func toggleTone() {
        AppSettings.shared.muteToneEnabled = (toneCheckbox.state == .on)
    }

    @objc private func toggleBanner() {
        AppSettings.shared.bannerKillerEnabled = (bannerCheckbox.state == .on)
    }

    @objc private func volumeChanged() {
        AppSettings.shared.toneVolume = volumeSlider.doubleValue
        // Preview the cue at the new volume (only if the cue is enabled).
        if AppSettings.shared.muteToneEnabled {
            ToneService.shared.play(muted: false)
        }
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
