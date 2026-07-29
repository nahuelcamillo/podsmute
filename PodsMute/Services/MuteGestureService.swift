//
//  MuteGestureService.swift
//  PodsMute
//
//  Receives the AirPods press-to-mute gesture via the official
//  AVAudioApplication API (macOS 14+). The system only delivers the
//  gesture to processes with active audio input, so this service keeps
//  a silent tap on the default input device while enabled.
//
//  That tap does NOT survive an audio route change on its own: AVAudioEngine
//  stops itself when its I/O configuration changes (an incoming iPhone call
//  steals the AirPods, they come back when it ends). The service therefore
//  tracks "armed" as an intent and rebuilds the tap whenever the route moves
//  or the engine is found stopped.
//

import Foundation
import AVFAudio
import AVFoundation
import CoreAudio

/// Captures the AirPods stem press using AVAudioApplication.
///
/// The system routes the mute gesture to apps with an active input stream
/// that registered an input mute state change handler. On gesture, the
/// handler fires with the new mute state; we accept it and notify.
final class MuteGestureService {

    // MARK: - Properties

    /// Called on the main queue when the user performs the mute gesture.
    /// Parameter is the new mute state requested by the system.
    ///
    /// The handler must accept the change (return true): rejecting it makes
    /// the system show "Cannot Control Mic" and skip the confirmation tones.
    var onGesture: ((Bool) -> Void)?

    /// Called on the main queue every time the silent tap is (re)established.
    /// The caller should re-publish its mute state to the system: a route
    /// change can leave the per-process mute the system tracks out of sync,
    /// and the stem toggles from THAT state — the first press would then carry
    /// a value we already hold and be dropped as an echo.
    var onArmed: (() -> Void)?

    /// Recreated on every arm, NOT reused. An AVAudioEngine binds its input
    /// node to the device it was built against; after a route change the same
    /// instance keeps negotiating for the old device and `start()` fails
    /// forever with -10868 (format not supported), no matter how many retries.
    /// A fresh engine resolves the current default input cleanly.
    private var engine = AVAudioEngine()

    /// Intent: a call is in progress and the gesture should be listening.
    /// Unlike `isRunning` this survives engine restarts.
    private(set) var armed = false

    /// Whether the silent tap is installed and the engine was started.
    private var isRunning = false

    /// True while the gesture can actually reach us (armed AND the tap alive).
    var isLive: Bool { armed && isRunning && engine.isRunning }

    private var handlerRegistered = false
    private var observersInstalled = false

    // The system invokes the handler right after registration (and around
    // engine starts) to publish the current state; that is not a user gesture
    // and must not toggle.
    private var armedAt: Date?
    private var sawInitialSync = false

    // Re-arm bookkeeping.
    private var rearmPending = false
    private var startRetries = 0
    private let maxStartRetries = 6      // with backoff below, ~20s of budget
    private var startGeneration = 0     // bumped to cancel pending retries
    /// Set once a whole retry budget is exhausted, so the watchdog stops
    /// logging the same failure every couple of seconds when there is no
    /// usable input device at all.
    private var armGaveUp = false
    private var watchdog: Timer?
    private var watchdogTicks = 0
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    // MARK: - Public Methods

    /// Request mic permission, register the gesture handler and start the input tap.
    func start() {
        armed = true
        installObservers()
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else {
                print("[MuteGesture] Microphone permission DENIED - gesture cannot work")
                return
            }
            DispatchQueue.main.async {
                guard let self = self, self.armed else { return }
                self.arm()
                self.startWatchdog()
            }
        }
    }

    /// Stop the input tap (releases the mic; gesture stops being delivered).
    func stop() {
        armed = false
        startGeneration &+= 1
        startRetries = 0
        armGaveUp = false
        stopWatchdog()
        teardownEngine()
    }

    /// Rebuild the tap now. Public so a manual recovery (menu item, SIGUSR1)
    /// can un-wedge the gesture without restarting the app.
    func rearmNow() {
        guard armed else {
            print("[MuteGesture] re-arm requested but not armed (no call in progress)")
            return
        }
        armGaveUp = false
        rearm(reason: "manual request")
    }

    // MARK: - Private Methods - Arming

    /// (Re)establish the handler and the silent tap on a fresh engine.
    private func arm() {
        // Open the state-sync window BEFORE touching the handler or the engine:
        // both registration and engine.start() can make the system call the
        // handler to publish the current state, which is not a user gesture.
        armedAt = Date()
        sawInitialSync = false
        engine = AVAudioEngine()    // see the `engine` declaration
        registerHandler()
        startEngine()
    }

    /// Schedule a rebuild of the tap after letting the HAL settle.
    ///
    /// - Parameter resetBudget: whether this is a fresh trigger (a route
    ///   change) that deserves a full retry budget. The watchdog passes false:
    ///   it fires every 2s and would otherwise refill the budget forever, so a
    ///   permanently unusable input could never reach "gave up".
    private func rearm(reason: String, resetBudget: Bool = true) {
        guard armed, !rearmPending else { return }
        rearmPending = true
        if !armGaveUp { print("[MuteGesture] re-arming (\(reason))") }
        startGeneration &+= 1        // cancel retries from the previous cycle
        if resetBudget { startRetries = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.rearmPending = false
            guard self.armed else { return }
            self.teardownEngine()
            self.arm()
        }
    }

    private func startEngine() {
        guard armed, !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // The input format is invalid (0 Hz / 0 ch) for a beat while the route
        // renegotiates — AirPods coming back from an iPhone call, or switching
        // to HFP as a call opens the mic. Wait instead of tapping a
        // half-initialized node.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            scheduleStartRetry(reason: "input not ready (\(Int(format.sampleRate))Hz/\(format.channelCount)ch)")
            return
        }

        // Silent tap: we discard the buffers, we only need the input running so
        // the system considers us an active mic client.
        //
        // format MUST be nil (the node's native format). Passing the format read
        // above races the route: mid-handoff the node renegotiates between the
        // read and the tap, and AVFAudio throws 'Failed to create tap due to
        // format mismatch' — an NSException Swift cannot catch, killing the app.
        // We never look at the buffers, so the native format is all we need.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { _, _ in }

        // Starting the engine can trigger the state-sync callback too.
        armedAt = Date()
        sawInitialSync = false

        do {
            try engine.start()
            isRunning = true
            startRetries = 0
            armGaveUp = false
            print("[MuteGesture] engine started (mic active, gesture armed) input=\(format)")
            onArmed?()
        } catch {
            print("[MuteGesture] engine start FAILED: \(error)")
            teardownEngine()          // never leave the tap behind
            scheduleStartRetry(reason: "engine start failed")
        }
    }

    /// Tear the tap down. Unconditional on purpose: a failed start leaves a tap
    /// installed with `isRunning` still false, and installing a second tap on
    /// the same bus throws an AVFAudio exception that Swift cannot catch.
    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if isRunning { print("[MuteGesture] engine stopped (mic released)") }
        isRunning = false
    }

    /// Retry the start shortly: the input device was not ready yet. Bounded so
    /// a permanently unusable input does not loop forever; the watchdog keeps
    /// probing at its own (slower) pace afterwards.
    private func scheduleStartRetry(reason: String) {
        guard startRetries < maxStartRetries else {
            startRetries = 0
            if !armGaveUp {
                print("[MuteGesture] \(reason); gave up arming for now (watchdog keeps trying)")
                armGaveUp = true
            }
            return
        }
        startRetries += 1
        // Backoff, and deliberately offset from AudioBridge's schedule: both
        // services open the same default input, and retrying in lockstep keeps
        // a Bluetooth device renegotiating (which audibly breaks up playback).
        let delay = min(0.8 * pow(2.0, Double(startRetries - 1)), 5.0)
        let gen = startGeneration
        if !armGaveUp {
            print("[MuteGesture] \(reason); retry \(startRetries)/\(maxStartRetries) in \(delay)s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.armed, !self.isRunning,
                  self.startGeneration == gen else { return }
            // Through arm(), not startEngine(): a failed engine has to be
            // thrown away, retrying on the same instance fails identically.
            self.teardownEngine()
            self.arm()
        }
    }

    // MARK: - Private Methods - Route changes

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        // AVAudioEngine stops itself when its I/O configuration changes (the
        // AirPods leave for an iPhone call and come back). Without a rebuild
        // the tap stays dead, the system stops delivering the gesture to this
        // process, and only the menu bar / hotkey paths keep working.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self,
                  (note.object as? AVAudioEngine) === self.engine else { return }
            // Building a fresh engine reconfigures the I/O and can post this
            // notification itself; reacting to it would loop. Anything within
            // the arm window is our own doing and already handled.
            if let armedAt = self.armedAt, Date().timeIntervalSince(armedAt) < 1.0 { return }
            self.armGaveUp = false
            self.rearm(reason: "engine configuration changed")
        }

        // Belt and braces: the input route can move without the engine
        // notifying us (device stolen rather than reconfigured).
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self = self, self.armed else { return }
                self.armGaveUp = false
                self.rearm(reason: "default input device changed")
            }
        }
        defaultInputListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, listener)

        // Also observe the notification (fires on every mute state change).
        NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            let key = AVAudioApplication.muteStateKey
            let state = note.userInfo?[key] ?? "?"
            print("[MuteGesture] inputMuteStateChangeNotification: muted=\(state)")
        }
    }

    /// Last line of defence: neither signal above is guaranteed to arrive, so
    /// poll for "armed but the tap is not running" and rebuild.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.armed, !self.rearmPending else { return }
            self.watchdogTicks += 1
            guard !self.engine.isRunning else { return }
            // Once the retry budget is exhausted the input is not merely busy,
            // it is unusable (no device, permission revoked). Probe every ~30s
            // instead of every 2s: reopening a Bluetooth input on a tight loop
            // keeps the link renegotiating and breaks up playback.
            if self.armGaveUp, self.watchdogTicks % 15 != 0 { return }
            self.rearm(reason: "watchdog: tap not running", resetBudget: false)
        }
        print("[MuteGesture] watchdog armed (rebuilds the tap after route changes)")
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: - Private Methods - Handler

    private func registerHandler() {
        // Handler: system calls this when the user presses the AirPods stem.
        // Return true to accept the state change.
        //
        // Re-registered on every arm: the system can drop the registration
        // when the audio accessory session is torn down (iPhone call handoff),
        // and re-registering is idempotent (it replaces the block).
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] muted in
                guard let self = self else { return false }

                if !self.sawInitialSync, let armed = self.armedAt,
                   Date().timeIntervalSince(armed) < 2.0 {
                    self.sawInitialSync = true
                    print("[MuteGesture] initial state sync (muted=\(muted)) - ignored")
                    return true
                }

                print("[MuteGesture] GESTURE handler fired: muted=\(muted)")
                DispatchQueue.main.async {
                    self.onGesture?(muted)
                }
                return true
            }
            if !handlerRegistered {
                print("[MuteGesture] input mute state change handler registered")
            }
            handlerRegistered = true
        } catch {
            print("[MuteGesture] FAILED to register handler: \(error)")
        }
    }
}
