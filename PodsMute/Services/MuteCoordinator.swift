//
//  MuteCoordinator.swift
//  PodsMute
//
//  Single entry point for every mute action (stem gesture, hotkey, menu
//  click). Picks the right mute mechanism for the moment:
//
//  - Stealth (bridge running): stop forwarding audio to the virtual mic.
//    A meeting app capturing BlackHole receives silence with no mute flag
//    anywhere, so it cannot detect a "system mute" (Meet would otherwise
//    auto-mute the participant and never auto-unmute).
//  - Classic (no bridge): the HAL mute flag on the default input device.
//
//  Defense: while stealth-muted, if some OTHER app captures a real device
//  directly (not BlackHole), the HAL flag is applied as well — staying
//  audible while believing you are muted is far worse than a meeting app
//  noticing a system mute.
//

import AVFAudio
import Combine
import CoreAudio
import Foundation

final class MuteCoordinator: ObservableObject {

    /// The user-facing mute state, whatever mechanism enforces it.
    @Published private(set) var isMuted = false

    /// Whether the stealth bridge is currently running.
    @Published private(set) var stealthActive = false

    private let audioController: AudioMuteController
    private let micUsageMonitor: MicUsageMonitor
    private let bridge = AudioBridge.shared
    private var cancellables = Set<AnyCancellable>()

    init(audioController: AudioMuteController, micUsageMonitor: MicUsageMonitor) {
        self.audioController = audioController
        self.micUsageMonitor = micUsageMonitor

        // Reflect HAL flag changes made elsewhere (Control Center, another
        // app). While bridging, an external flag also silences our capture
        // stream, so it still mutes the call de facto.
        audioController.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] flagMuted in
                guard let self = self else { return }
                let effective = self.stealthActive ? (self.bridge.muted || flagMuted) : flagMuted
                if self.isMuted != effective { self.isMuted = effective }
            }
            .store(in: &cancellables)
    }

    // MARK: - Call lifecycle (driven by MicUsageMonitor)

    /// External capture started: bring up the stealth bridge if enabled and
    /// BlackHole is installed. Failure means classic flag-mute keeps working.
    func callDidStart() {
        guard AppSettings.shared.stealthMuteEnabled else { return }
        startBridge()
    }

    /// External capture ended: tear the bridge down and leave the mic open
    /// for the next meeting.
    func callDidEnd() {
        stopBridge()
        if isMuted { setMute(false) }
    }

    /// The set of devices other apps capture changed mid-call; re-apply the
    /// current mute so the defense flag tracks reality (1s poll granularity).
    func externalCaptureDevicesChanged() {
        guard stealthActive, isMuted else { return }
        applyMute(true)
    }

    /// The Preferences toggle changed; honor it immediately if a call is on.
    func stealthSettingChanged() {
        guard micUsageMonitor.othersCapturing else { return }
        if AppSettings.shared.stealthMuteEnabled {
            startBridge()
        } else {
            stopBridge()
        }
        applyMute(isMuted)
    }

    // MARK: - Mute

    func toggleMute() { setMute(!isMuted) }

    func setMute(_ muted: Bool) {
        applyMute(muted)
        if isMuted != muted { isMuted = muted }
    }

    private func applyMute(_ muted: Bool) {
        // A failed mid-call restart (device vanished) can strand the flag;
        // keep the published indicator honest on every interaction.
        if stealthActive != bridge.running { stealthActive = bridge.running }
        if bridge.running {
            bridge.muted = muted
            // Defense: the bridge cannot silence an app capturing a real
            // device directly; cover it with the HAL flag.
            let needsFlag = muted && captureBypassesBridge()
            if needsFlag != audioController.isMuted {
                audioController.setMute(needsFlag)
            }
            print("[MuteCoordinator] stealth mute=\(muted) defenseFlag=\(needsFlag)")
        } else {
            audioController.setMute(muted)
        }
        // Keep the per-process input mute the system tracks in sync:
        // - the stem gesture toggles from the state the system believes, so
        //   a hotkey mute would otherwise leave the gesture tones one press
        //   out of phase;
        // - while bridging, the system-applied process mute silences our own
        //   capture stream — an extra layer of real silence.
        // Programmatic setInputMuted does NOT trigger the system banner.
        try? AVAudioApplication.shared.setInputMuted(muted)
    }

    // MARK: - Bridge

    private func startBridge() {
        guard !bridge.running else { stealthActive = true; return }
        if bridge.start() {
            bridge.muted = isMuted
            stealthActive = true
        } else {
            stealthActive = false
            print("[MuteCoordinator] bridge unavailable; classic flag-mute in effect")
        }
    }

    private func stopBridge() {
        bridge.stop()
        bridge.muted = false
        stealthActive = false
    }

    /// True if any external process captures a device other than BlackHole,
    /// i.e. audio that does not flow through (and cannot be cut by) the bridge.
    private func captureBypassesBridge() -> Bool {
        let external = micUsageMonitor.capturedInputDevices
        guard !external.isEmpty else { return false }
        guard let virtualID = AudioBridge.virtualDeviceID else { return true }
        return !external.subtracting([virtualID]).isEmpty
    }
}
