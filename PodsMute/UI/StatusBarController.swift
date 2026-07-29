//
//  StatusBarController.swift
//  PodsMute
//
//  Controls the menu bar status item and dropdown menu.
//

import Cocoa
import Combine

/// Manages the menu bar status item with mic icon and dropdown menu.
final class StatusBarController: NSObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem
    private let muteCoordinator: MuteCoordinator
    private let bluetoothManager: BluetoothManager

    /// Whether the stem gesture is currently listening: nil when it is not
    /// armed at all (no call in progress), true/false when armed.
    var gestureIsLive: (() -> Bool?)?

    /// Rebuild the stem gesture's mic tap (manual recovery from the menu).
    var onRearmGesture: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var toneMenuItem: NSMenuItem?

    // Menu item tags for updating
    private enum MenuItemTag: Int {
        case muteStatus = 100
        case connectionStatus = 101
        case deviceName = 102
        case stealthStatus = 103
        case gestureStatus = 104
    }

    // MARK: - Initialization

    init(muteCoordinator: MuteCoordinator, bluetoothManager: BluetoothManager) {
        self.muteCoordinator = muteCoordinator
        self.bluetoothManager = bluetoothManager

        // Create status bar item with variable length
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        setupButton()
        setupMenu()
        setupObservers()
        updateIcon()
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }

        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Set accessibility
        button.setAccessibilityLabel("PodsMute")
        button.setAccessibilityHelp("Click to toggle microphone mute, right-click for menu")
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Mute status (read-only display)
        let muteStatusItem = NSMenuItem(
            title: "Microphone: --",
            action: nil,
            keyEquivalent: ""
        )
        muteStatusItem.tag = MenuItemTag.muteStatus.rawValue
        muteStatusItem.isEnabled = false
        menu.addItem(muteStatusItem)

        // Stealth mode indicator (only visible while the bridge runs)
        let stealthItem = NSMenuItem(
            title: "Stealth mute: active",
            action: nil,
            keyEquivalent: ""
        )
        stealthItem.tag = MenuItemTag.stealthStatus.rawValue
        stealthItem.isEnabled = false
        stealthItem.isHidden = true
        stealthItem.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: nil)
        menu.addItem(stealthItem)

        // Stem gesture health (only shown during a call, i.e. while armed).
        // An audio route change can kill the gesture while every other mute
        // path keeps working, so surfacing it saves guessing.
        let gestureItem = NSMenuItem(
            title: "Stem gesture: --",
            action: nil,
            keyEquivalent: ""
        )
        gestureItem.tag = MenuItemTag.gestureStatus.rawValue
        gestureItem.isEnabled = false
        gestureItem.isHidden = true
        menu.addItem(gestureItem)

        // Toggle mute action
        let toggleItem = NSMenuItem(
            title: "Toggle Mute",
            action: #selector(toggleMute),
            keyEquivalent: "m"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Manual recovery for the stem gesture (the automatic re-arm should
        // cover it, but during a meeting this beats restarting the app).
        let rearmItem = NSMenuItem(
            title: "Re-arm Stem Gesture",
            action: #selector(rearmGesture),
            keyEquivalent: ""
        )
        rearmItem.target = self
        menu.addItem(rearmItem)

        menu.addItem(NSMenuItem.separator())

        // Connection section header
        let connectionHeader = NSMenuItem(
            title: "AirPods",
            action: nil,
            keyEquivalent: ""
        )
        connectionHeader.isEnabled = false
        menu.addItem(connectionHeader)

        // Connection status
        let connectionItem = NSMenuItem(
            title: "Status: Disconnected",
            action: nil,
            keyEquivalent: ""
        )
        connectionItem.tag = MenuItemTag.connectionStatus.rawValue
        connectionItem.isEnabled = false
        menu.addItem(connectionItem)

        // Device name
        let deviceItem = NSMenuItem(
            title: "Device: --",
            action: nil,
            keyEquivalent: ""
        )
        deviceItem.tag = MenuItemTag.deviceName.rawValue
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)

        menu.addItem(NSMenuItem.separator())

        // Reconnect option
        let reconnectItem = NSMenuItem(
            title: "Reconnect",
            action: #selector(reconnect),
            keyEquivalent: "r"
        )
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences: toggle the distinctive mute/unmute audio cue
        let toneItem = NSMenuItem(
            title: "Mute/Unmute Sound",
            action: #selector(toggleMuteTone(_:)),
            keyEquivalent: ""
        )
        toneItem.target = self
        toneItem.state = AppSettings.shared.muteToneEnabled ? .on : .off
        menu.addItem(toneItem)
        toneMenuItem = toneItem

        // Preferences window (configurable shortcuts, etc.)
        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(
            title: "About PodsMute",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func setupObservers() {
        // Observe mute state changes
        muteCoordinator.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.updateMenuItems()
            }
            .store(in: &cancellables)

        // Observe the stealth bridge starting/stopping
        muteCoordinator.$stealthActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuItems()
            }
            .store(in: &cancellables)

        // Observe connection state changes
        bluetoothManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuItems()
            }
            .store(in: &cancellables)

        // Observe device name changes
        bluetoothManager.$connectedDeviceName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuItems()
            }
            .store(in: &cancellables)

        // Observe appearance changes (light/dark mode)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }

        // Keep the cue menu item in sync no matter where it was toggled.
        NotificationCenter.default.addObserver(
            forName: .podsMuteToneEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncToneMenuItem()
        }
    }

    // MARK: - UI Updates

    /// Update the menu bar icon based on mute state
    func updateIcon() {
        guard let button = statusItem.button else { return }

        button.image = createStatusBarIcon(isMuted: muteCoordinator.isMuted)

        // Update tooltip
        let muteStatus = muteCoordinator.isMuted ? "Muted" : "Unmuted"
        let connectionStatus = bluetoothManager.connectionState.displayName
        button.toolTip = "Microphone: \(muteStatus)\nAirPods: \(connectionStatus)"
    }

    /// Create the menu bar icon for the current mute state.
    ///
    /// Uses a standard SF Symbol as a template image (auto-adapts to light/dark
    /// and to the menu bar tint). The hand-drawn headphones+badge icon used
    /// before rendered with zero width on macOS 26 and never appeared.
    private func createStatusBarIcon(isMuted: Bool) -> NSImage? {
        let symbolName = isMuted ? "mic.slash.fill" : "mic.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PodsMute")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func updateMenuItems() {
        guard let menu = statusItem.menu else { return }

        // Update mute status with colored text
        if let muteItem = menu.item(withTag: MenuItemTag.muteStatus.rawValue) {
            let status = muteCoordinator.isMuted ? "Muted" : "Unmuted"
            let statusColor: NSColor = muteCoordinator.isMuted ? .systemRed : .systemGreen

            // Create attributed string with colored status
            let fullText = "Microphone: \(status)"
            let attributedTitle = NSMutableAttributedString(string: fullText)

            // Color just the status part
            let statusRange = (fullText as NSString).range(of: status)
            attributedTitle.addAttribute(.foregroundColor, value: statusColor, range: statusRange)

            muteItem.attributedTitle = attributedTitle

            // Add indicator icon
            if muteCoordinator.isMuted {
                muteItem.image = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: nil)
            } else {
                muteItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
            }
        }

        // Show the stealth indicator only while the bridge is live
        if let stealthItem = menu.item(withTag: MenuItemTag.stealthStatus.rawValue) {
            stealthItem.isHidden = !muteCoordinator.stealthActive
        }

        // Stem gesture health: hidden outside calls, red when armed but dead.
        if let gestureItem = menu.item(withTag: MenuItemTag.gestureStatus.rawValue) {
            let live = gestureIsLive?()
            gestureItem.isHidden = (live == nil)
            if let live = live {
                let statusText = live ? "listening" : "not listening"
                let fullText = "Stem gesture: \(statusText)"
                let attributed = NSMutableAttributedString(string: fullText)
                attributed.addAttribute(
                    .foregroundColor,
                    value: live ? NSColor.systemGreen : NSColor.systemRed,
                    range: (fullText as NSString).range(of: statusText))
                gestureItem.attributedTitle = attributed
                gestureItem.image = NSImage(
                    systemSymbolName: live ? "hand.tap" : "exclamationmark.triangle",
                    accessibilityDescription: nil)
            }
        }

        // Update connection status with colored text
        if let connectionItem = menu.item(withTag: MenuItemTag.connectionStatus.rawValue) {
            let statusText = bluetoothManager.connectionState.displayName
            let fullText = "Status: \(statusText)"

            // Add indicator icon
            let imageName: String
            let statusColor: NSColor

            switch bluetoothManager.connectionState {
            case .connected:
                imageName = "checkmark.circle.fill"
                statusColor = .systemGreen
            case .connecting:
                imageName = "arrow.triangle.2.circlepath"
                statusColor = .systemOrange
            case .disconnected:
                imageName = "xmark.circle"
                statusColor = .secondaryLabelColor
            }

            // Create attributed string with colored status
            let attributedTitle = NSMutableAttributedString(string: fullText)
            let statusRange = (fullText as NSString).range(of: statusText)
            attributedTitle.addAttribute(.foregroundColor, value: statusColor, range: statusRange)

            connectionItem.attributedTitle = attributedTitle
            connectionItem.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        }

        // Update device name
        if let deviceItem = menu.item(withTag: MenuItemTag.deviceName.rawValue) {
            if let name = bluetoothManager.connectedDeviceName {
                deviceItem.title = "Device: \(name)"
                deviceItem.isHidden = false
            } else {
                deviceItem.title = "Device: --"
                deviceItem.isHidden = !bluetoothManager.isConnected
            }
        }
    }

    // MARK: - Actions

    @objc private func statusBarButtonClicked(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: show menu (handled automatically by NSStatusItem)
            statusItem.button?.performClick(nil)
        } else {
            // Left-click: toggle mute
            toggleMute()
        }
    }

    @objc private func toggleMute() {
        muteCoordinator.toggleMute()
    }

    @objc private func rearmGesture() {
        onRearmGesture?()
    }

    @objc private func reconnect() {
        bluetoothManager.autoConnectToPairedDevice()
    }

    @objc private func toggleMuteTone(_ sender: NSMenuItem) {
        // The checkmark updates via .podsMuteToneEnabledChanged observer.
        AppSettings.shared.muteToneEnabled.toggle()
    }

    /// Refresh the cue menu item checkmark (e.g. after toggling via hotkey).
    func syncToneMenuItem() {
        toneMenuItem?.state = AppSettings.shared.muteToneEnabled ? .on : .off
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)

        // Get version info
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        // Create about window
        let alert = NSAlert()
        alert.messageText = "PodsMute"
        alert.informativeText = "Control your microphone mute state with your AirPods.\n\nSupports AirPods Max and AirPods Pro.\n\nVersion \(version) (\(build))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Set app icon
        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }

        alert.runModal()
    }

}

// MARK: - NSMenuDelegate

extension StatusBarController: NSMenuDelegate {

    /// The gesture health is polled, not published; refresh it as the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuItems()
    }
}
