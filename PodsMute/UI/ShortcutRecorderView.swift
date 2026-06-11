//
//  ShortcutRecorderView.swift
//  PodsMute
//
//  A click-to-record control for a keyboard shortcut. Click it, press the
//  combination, and it captures it; the × clears it; Esc cancels recording.
//

import Cocoa

final class ShortcutRecorderView: NSView {

    /// Called with the new shortcut (or nil when cleared).
    var onChange: ((Shortcut?) -> Void)?

    private(set) var shortcut: Shortcut?
    private let recordButton = NSButton()
    private let clearButton = NSButton()
    private var monitor: Any?
    private var recording = false

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        setup()
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { removeMonitor() }

    // MARK: - Setup

    private func setup() {
        recordButton.bezelStyle = .rounded
        recordButton.setButtonType(.momentaryPushIn)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordButton)

        clearButton.bezelStyle = .circular
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Clear shortcut")
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            recordButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            recordButton.widthAnchor.constraint(equalToConstant: 160),
            clearButton.leadingAnchor.constraint(equalTo: recordButton.trailingAnchor, constant: 4),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            trailingAnchor.constraint(equalTo: clearButton.trailingAnchor),
        ])
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        recordButton.title = "Type shortcut…"
        recordButton.highlight(true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.recording else { return event }
            if event.type == .flagsChanged {
                self.showLiveModifiers(event.modifierFlags)
                return event
            }
            // keyDown
            if event.keyCode == 53 { // Escape cancels
                self.stopRecording()
                return nil
            }
            if let captured = Shortcut(event: event) {
                self.shortcut = captured
                self.onChange?(captured)
                self.stopRecording()
            }
            return nil // consume keys while recording (don't type into anything)
        }
    }

    private func stopRecording() {
        recording = false
        removeMonitor()
        recordButton.highlight(false)
        refreshTitle()
    }

    private func removeMonitor() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: - Actions

    @objc private func clearShortcut() {
        shortcut = nil
        onChange?(nil)
        if recording { stopRecording() } else { refreshTitle() }
    }

    // MARK: - Display

    func setShortcut(_ shortcut: Shortcut?) {
        self.shortcut = shortcut
        refreshTitle()
    }

    private func refreshTitle() {
        recordButton.title = shortcut?.displayString ?? "Click to record"
        clearButton.isHidden = (shortcut == nil)
    }

    private func showLiveModifiers(_ flags: NSEvent.ModifierFlags) {
        let mods = Shortcut.modifierString(Shortcut.carbonModifiers(from: flags))
        recordButton.title = mods.isEmpty ? "Type shortcut…" : mods + "…"
    }
}
