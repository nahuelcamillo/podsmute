//
//  AppDelegate.swift
//  PodsMute
//
//  Application delegate handling app lifecycle and service initialization.
//

import Cocoa

/// Main application delegate.
///
/// Responsibilities:
/// - Initialize and wire up all services
/// - Monitor audioaccessoryd Darwin notifications for AirPods mute events
/// - Toggle system mute when AirPods button is pressed
/// - Handle app lifecycle events
///
/// The key insight: audioaccessoryd emits Darwin notifications (com.apple.audioaccessoryd.MuteState)
/// when AirPods triggers a mute action. We listen for these native events.
/// Supports AirPods Max and AirPods Pro.
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services

    private var audioController: AudioMuteController!
    private var muteCoordinator: MuteCoordinator!
    private var audioAccessoryMonitor: AudioAccessoryMonitor!
    private var muteGestureService: MuteGestureService!
    private var micUsageMonitor: MicUsageMonitor!
    private var bannerKiller: BannerKiller!
    private var toneService: ToneService!
    private var hotKeyService: HotKeyService!
    private var statusBarController: StatusBarController!
    private var sigtermSource: DispatchSourceSignal?
    // Debug hook: SIGUSR2 toggles mute as if the hotkey fired (no keyboard
    // or AirPods needed when testing over SSH / scripts).
    private var usr2Source: DispatchSourceSignal?

    // Keep reference to BluetoothManager for device detection (status display)
    private var bluetoothManager: BluetoothManager!

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] Application launching...")

        // Initialize services
        setupServices()

        // Setup audioaccessoryd notification monitoring
        setupAudioAccessoryMonitoring()

        // Setup the official AVAudioApplication mute gesture path (macOS 14+)
        setupMuteGesture()

        // Global keyboard shortcuts (work even if the menu bar icon is hidden)
        setupHotKeys()

        // kill/logout sends SIGTERM, which skips applicationWillTerminate and
        // would leave the mic muted; route it through graceful termination.
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { NSApp.terminate(nil) }
        sigtermSource?.resume()

        signal(SIGUSR2, SIG_IGN)
        usr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        usr2Source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.muteCoordinator.toggleMute()
            print("[AppDelegate] SIGUSR2 -> muted = \(self.muteCoordinator.isMuted)")
            self.presentMuteFeedback()
        }
        usr2Source?.resume()

        print("[AppDelegate] Application ready")
        print("[AppDelegate] Press your AirPods button to toggle mute")
        print("[AppDelegate] Listening for audioaccessoryd mute state notifications...")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] Application terminating...")

        // Restore mic to unmuted state if it was muted by this app
        if muteCoordinator.isMuted {
            print("[AppDelegate] Restoring microphone to unmuted state...")
            muteCoordinator.setMute(false)
        }

        AudioBridge.shared.stop()
        audioAccessoryMonitor?.stopMonitoring()
        micUsageMonitor?.stop()
        muteGestureService?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Setup

    private func setupServices() {
        // Create audio controller first (no dependencies)
        audioController = AudioMuteController()

        // Create Bluetooth manager (for device status display)
        bluetoothManager = BluetoothManager()

        // Create audio accessory monitor (for AirPods crown button detection)
        audioAccessoryMonitor = AudioAccessoryMonitor()

        // Create mute gesture service (official AVAudioApplication API)
        muteGestureService = MuteGestureService()

        // Create external mic usage monitor (arms the gesture only during calls)
        micUsageMonitor = MicUsageMonitor()

        // Single mute entry point: stealth bridge during calls, HAL flag otherwise
        muteCoordinator = MuteCoordinator(
            audioController: audioController,
            micUsageMonitor: micUsageMonitor
        )

        // Create the system banner dismisser (needs Accessibility permission)
        bannerKiller = BannerKiller()
        bannerKiller.requestPermission()

        // The distinctive mute/unmute audio cue (shared so Preferences can preview)
        toneService = ToneService.shared

        // Create the global hotkey service
        hotKeyService = HotKeyService()

        // Create status bar controller
        statusBarController = StatusBarController(
            muteCoordinator: muteCoordinator,
            bluetoothManager: bluetoothManager
        )

        // Honor the stealth toggle immediately when changed mid-call.
        NotificationCenter.default.addObserver(
            forName: .podsMuteStealthModeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.muteCoordinator.stealthSettingChanged()
        }
    }

    private func setupAudioAccessoryMonitoring() {
        // Set up callback for mute state changes from AirPods
        audioAccessoryMonitor.onMuteStateChanged = { [weak self] state in
            guard let self = self else { return }

            print("[AppDelegate] AirPods mute state notification received!")

            // Toggle system mute when AirPods triggers mute
            self.muteCoordinator.toggleMute()
            self.presentMuteFeedback()
        }

        // Debug: log all notifications
        audioAccessoryMonitor.onNotification = { notification in
            print("[AppDelegate] Audio accessory notification: \(notification)")
        }

        // Start monitoring
        let success = audioAccessoryMonitor.startMonitoring()

        if success {
            print("[AppDelegate] Audio accessory monitoring started successfully")
        } else {
            print("[AppDelegate] WARNING: Failed to start audio accessory monitoring")
        }
    }

    private func setupMuteGesture() {
        // Mirror the state the system applied to our process, so the global
        // mute stays phase-locked with the AirPods confirmation tones.
        muteGestureService.onGesture = { [weak self] muted in
            guard let self = self else { return }
            // The coordinator syncs the process mute back to the system on
            // every change; that echo lands here with the state we already
            // hold. A real stem press always carries a NEW state.
            guard muted != self.muteCoordinator.isMuted else {
                print("[AppDelegate] Gesture echo (muted=\(muted)) - ignored")
                return
            }
            self.muteCoordinator.setMute(muted)
            print("[AppDelegate] Gesture -> mute = \(self.muteCoordinator.isMuted)")
            self.presentMuteFeedback()
            // The system banner spawns with the gesture; hunt it down now (opt-out)
            if AppSettings.shared.bannerKillerEnabled {
                self.bannerKiller.huntBanner()
            }
        }

        // Arm the gesture only while another app captures the mic. This keeps
        // the AirPods out of call mode (HFP) when idle: music quality stays
        // intact and the stem keeps doing play/pause outside of calls.
        // The stealth bridge shares this exact lifecycle.
        micUsageMonitor.onChange = { [weak self] othersCapturing in
            guard let self = self else { return }
            if othersCapturing {
                print("[AppDelegate] External mic usage detected - arming gesture")
                self.muteGestureService.start()
                self.muteCoordinator.callDidStart()
            } else {
                print("[AppDelegate] No external mic usage - disarming gesture")
                self.muteGestureService.stop()
                // Tears the bridge down and leaves the mic open for next time.
                self.muteCoordinator.callDidEnd()
            }
        }

        // Mid-call changes to WHICH devices other apps capture feed the
        // stealth defense (an app capturing the real mic bypasses the bridge).
        micUsageMonitor.onCapturedDevicesChange = { [weak self] _ in
            self?.muteCoordinator.externalCaptureDevicesChanged()
        }

        // The initial check fires onChange if a call is already in progress.
        micUsageMonitor.start()
    }

    // MARK: - Global Hotkeys

    private func setupHotKeys() {
        hotKeyService.start()
        registerShortcuts()
        // Re-register whenever the user edits a shortcut in Preferences.
        NotificationCenter.default.addObserver(
            self, selector: #selector(shortcutsChanged),
            name: .podsMuteShortcutsChanged, object: nil)
    }

    @objc private func shortcutsChanged() {
        hotKeyService.unregisterAll()
        registerShortcuts()
    }

    /// Register the (configurable) global shortcuts from preferences.
    /// - Mute: toggles via CoreAudio directly (works without AirPods, no banner).
    /// - Sound: toggles the cue; plays a sample when turned on, silence when off.
    private func registerShortcuts() {
        hotKeyService.register(AppSettings.shared.muteShortcut) { [weak self] in
            guard let self = self else { return }
            self.muteCoordinator.toggleMute()
            print("[AppDelegate] Mute shortcut -> mute = \(self.muteCoordinator.isMuted)")
            self.presentMuteFeedback()
        }
        hotKeyService.register(AppSettings.shared.toggleSoundShortcut) { [weak self] in
            guard let self = self else { return }
            AppSettings.shared.muteToneEnabled.toggle()
            let enabled = AppSettings.shared.muteToneEnabled
            print("[AppDelegate] Sound shortcut -> cue enabled = \(enabled)")
            // Menu/checkbox sync happens via .podsMuteToneEnabledChanged.
            if enabled { self.toneService.play(muted: false) }
        }
    }

    /// Shared mute feedback: icon, capture-proof HUD, and the optional cue.
    private func presentMuteFeedback() {
        statusBarController.updateIcon()
        MuteHUD.shared.show(muted: muteCoordinator.isMuted)
        if AppSettings.shared.muteToneEnabled {
            toneService.play(muted: muteCoordinator.isMuted)
        }
    }

}
