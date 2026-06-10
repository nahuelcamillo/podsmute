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
    private var audioAccessoryMonitor: AudioAccessoryMonitor!
    private var muteGestureService: MuteGestureService!
    private var micUsageMonitor: MicUsageMonitor!
    private var bannerKiller: BannerKiller!
    private var statusBarController: StatusBarController!
    private var sigtermSource: DispatchSourceSignal?

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

        // kill/logout sends SIGTERM, which skips applicationWillTerminate and
        // would leave the mic muted; route it through graceful termination.
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { NSApp.terminate(nil) }
        sigtermSource?.resume()

        print("[AppDelegate] Application ready")
        print("[AppDelegate] Press your AirPods button to toggle mute")
        print("[AppDelegate] Listening for audioaccessoryd mute state notifications...")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] Application terminating...")

        // Restore mic to unmuted state if it was muted by this app
        if audioController.isMuted {
            print("[AppDelegate] Restoring microphone to unmuted state...")
            audioController.setMute(false)
        }

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

        // Create the system banner dismisser (needs Accessibility permission)
        bannerKiller = BannerKiller()
        bannerKiller.requestPermission()

        // Create status bar controller
        statusBarController = StatusBarController(
            audioController: audioController,
            bluetoothManager: bluetoothManager
        )

        // Check for paired AirPods (for status display)
        checkForAirPods()
    }

    private func setupAudioAccessoryMonitoring() {
        // Set up callback for mute state changes from AirPods
        audioAccessoryMonitor.onMuteStateChanged = { [weak self] state in
            guard let self = self else { return }

            print("[AppDelegate] AirPods mute state notification received!")

            // Toggle system mute when AirPods triggers mute
            self.audioController.toggleMute()
            self.statusBarController.updateIcon()
            MuteHUD.shared.show(muted: self.audioController.isMuted)
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
            self.audioController.setMute(muted)
            print("[AppDelegate] Gesture -> system-wide mute = \(self.audioController.isMuted)")
            self.statusBarController.updateIcon()
            // HUD excluded from screen capture - participants never see it
            MuteHUD.shared.show(muted: self.audioController.isMuted)
            // The system banner spawns with the gesture; hunt it down now
            self.bannerKiller.huntBanner()
        }

        // Arm the gesture only while another app captures the mic. This keeps
        // the AirPods out of call mode (HFP) when idle: music quality stays
        // intact and the stem keeps doing play/pause outside of calls.
        micUsageMonitor.onChange = { [weak self] othersCapturing in
            guard let self = self else { return }
            if othersCapturing {
                print("[AppDelegate] External mic usage detected - arming gesture")
                self.muteGestureService.start()
            } else {
                print("[AppDelegate] No external mic usage - disarming gesture")
                self.muteGestureService.stop()
                // Leave the mic usable for the next meeting.
                if self.audioController.isMuted {
                    self.audioController.setMute(false)
                    self.statusBarController.updateIcon()
                }
            }
        }
        // The initial check fires onChange if a call is already in progress.
        micUsageMonitor.start()
    }

    private func checkForAirPods() {
        let devices = bluetoothManager.pairedDevices()

        if devices.isEmpty {
            print("[AppDelegate] No paired AirPods found")
            print("[AppDelegate] Please pair your AirPods Max or AirPods Pro and try again")
        } else {
            print("[AppDelegate] Found \(devices.count) paired AirPods device(s):")
            for device in devices {
                print("  - \(device.name) (\(device.id))")
            }
        }
    }
}
