//
//  MicUsageMonitor.swift
//  PodsMute
//
//  Detects whether any OTHER process is capturing audio input, using
//  CoreAudio process objects (macOS 14.4+). This lets the app arm the
//  mute gesture only during real calls, so the AirPods are not held in
//  call mode (HFP) while idle and the stem keeps its play/pause role.
//

import Foundation
import CoreAudio

/// Polls CoreAudio process objects to detect external microphone usage.
final class MicUsageMonitor {

    // MARK: - Properties

    /// Called on the main queue when external capture starts (true) or ends (false).
    var onChange: ((Bool) -> Void)?

    /// Called on the main queue when the SET of devices captured by other
    /// processes changes (e.g. Meet's mic picker opens the real mic too).
    /// Fires after onChange when both change in the same poll.
    var onCapturedDevicesChange: ((Set<AudioDeviceID>) -> Void)?

    private(set) var othersCapturing = false

    /// Input devices currently held open by capturing external processes.
    private(set) var capturedInputDevices: Set<AudioDeviceID> = []

    private var timer: Timer?
    private let ownPID = getpid()

    // MARK: - Public Methods

    func start() {
        check()
        // Mic usage transitions are rare; 1s polling is cheap and robust.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.check()
        }
        print("[MicUsage] monitoring external microphone usage")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Private Methods

    private func check() {
        var devices = Set<AudioDeviceID>()
        var active = false
        for object in processObjects() {
            guard processPID(object) != ownPID else { continue }
            guard isRunningInput(object) else { continue }
            active = true
            devices.formUnion(inputDevices(of: object))
        }

        // onChange first: the bridge must be up before any device-set
        // reaction re-evaluates the mute defense (both run on main, FIFO).
        if active != othersCapturing {
            othersCapturing = active
            print("[MicUsage] other apps capturing: \(active)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onChange?(self.othersCapturing)
            }
        }

        if devices != capturedInputDevices {
            capturedInputDevices = devices
            print("[MicUsage] externally captured devices: \(devices.sorted())")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onCapturedDevicesChange?(self.capturedInputDevices)
            }
        }
    }

    /// Input devices a process holds open (kAudioProcessPropertyDevices,
    /// input scope). Validated on macOS 26 via `audioctl procs`.
    private func inputDevices(of object: AudioObjectID) -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private func processPID(_ object: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &pid) == noErr else { return -1 }
        return pid
    }

    private func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
