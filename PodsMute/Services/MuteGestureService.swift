//
//  MuteGestureService.swift
//  PodsMute
//
//  Receives the AirPods press-to-mute gesture via the official
//  AVAudioApplication API (macOS 14+). The system only delivers the
//  gesture to processes with active audio input, so this service keeps
//  a silent tap on the default input device while enabled.
//

import Foundation
import AVFAudio
import AVFoundation

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

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var handlerRegistered = false

    // The system invokes the handler once right after registration to sync
    // the current state; that is not a user gesture and must not toggle.
    private var armedAt: Date?
    private var sawInitialSync = false

    // MARK: - Public Methods

    /// Request mic permission, register the gesture handler and start the input tap.
    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else {
                print("[MuteGesture] Microphone permission DENIED - gesture cannot work")
                return
            }
            DispatchQueue.main.async {
                self?.registerHandler()
                self?.startEngine()
            }
        }
    }

    /// Stop the input tap (releases the mic; gesture stops being delivered).
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        print("[MuteGesture] engine stopped (mic released)")
    }

    // MARK: - Private Methods

    private func registerHandler() {
        guard !handlerRegistered else { return }

        // Handler: system calls this when the user presses the AirPods stem.
        // Return true to accept the state change.
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
            handlerRegistered = true
            print("[MuteGesture] input mute state change handler registered")
        } catch {
            print("[MuteGesture] FAILED to register handler: \(error)")
        }

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

    private func startEngine() {
        guard !isRunning else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            print("[MuteGesture] no valid input format - is an input device available?")
            return
        }

        // Silent tap: we discard the buffers, we only need the input running
        // so the system considers us an active mic client.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }

        // The system may fire the state-sync handler during engine.start(),
        // so the sync window must open before starting.
        armedAt = Date()
        sawInitialSync = false

        do {
            try engine.start()
            isRunning = true
            print("[MuteGesture] engine started (mic active, gesture armed)")
        } catch {
            print("[MuteGesture] engine start FAILED: \(error)")
        }
    }
}
