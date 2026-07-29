//
//  AudioMuteController.swift
//  PodsMute
//
//  Controls system-wide microphone mute state using Core Audio.
//

import Foundation
import CoreAudio
import Combine

/// Controller for managing system microphone mute state.
///
/// Uses Core Audio HAL APIs to get/set the mute property on the default input device.
/// Automatically tracks changes to the default input device and mute state.
final class AudioMuteController: ObservableObject {

    // MARK: - Published Properties

    /// Current mute state of the default input device
    @Published private(set) var isMuted: Bool = false

    /// Name of the current default input device
    @Published private(set) var inputDeviceName: String = "Unknown"

    /// Whether the input device supports muting
    @Published private(set) var supportsMute: Bool = false

    /// The current default input device. Published so the mute coordinator can
    /// react to the route moving (AirPods stolen by an incoming iPhone call).
    @Published private(set) var deviceID: AudioObjectID = kAudioObjectUnknown

    // MARK: - Private Properties

    private var defaultInputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteChangeListenerBlock: AudioObjectPropertyListenerBlock?

    /// Devices we set the mute flag on, so we can clear exactly those later.
    /// Tracking them is not bookkeeping for its own sake: the set of captured
    /// devices moves mid-call, and clearing the flag from "whatever is default
    /// now" would strand a muted device with no way back from the UI.
    private var flaggedDevices: Set<AudioObjectID> = []

    // MARK: - Initialization

    init() {
        refreshDefaultInputDevice()
        setupDeviceChangeListener()
    }

    deinit {
        removeListeners()
    }

    // MARK: - Public Methods

    /// Toggle the mute state of the default input device.
    func toggleMute() {
        setMute(!isMuted)
    }

    /// Set the mute state of the default input device.
    /// - Parameter muted: Whether to mute (true) or unmute (false)
    func setMute(_ muted: Bool) {
        setMute(muted, devices: defaultInputTarget())
    }

    /// Apply the HAL mute flag to an explicit set of input devices.
    ///
    /// The caller decides WHICH devices matter, because the default input is not
    /// necessarily the device being recorded: a meeting app can hold a device
    /// open that is not the default (Slack keeping the AirPods while the default
    /// moved to BlackHole). Flagging the default in that case mutes a device
    /// nobody is listening to and leaves the real one live — audible while the
    /// UI says muted.
    ///
    /// Unmuting ignores `devices` and clears every flag we set, so a device that
    /// dropped out of the set mid-call cannot stay muted behind our back.
    func setMute(_ muted: Bool, devices: Set<AudioObjectID>) {
        // Device IDs are reassigned when audio hardware changes; re-resolve
        // so we never act on a stale device.
        refreshDefaultInputDevice()

        if muted {
            guard !devices.isEmpty else {
                print("[AudioMuteController] No device to flag")
                return
            }
            for device in devices where applyFlag(true, to: device) {
                flaggedDevices.insert(device)
            }
            // Devices that left the set mid-call (the app switched mic): let
            // them go, we are the only reason they are muted.
            let stale = flaggedDevices.subtracting(devices)
            for device in stale { applyFlag(false, to: device) }
            flaggedDevices.subtract(stale)
        } else {
            for device in flaggedDevices { applyFlag(false, to: device) }
            flaggedDevices.removeAll()
        }

        // Reflect the default input's flag, which is what `isMuted` means (it
        // also has to catch mutes made outside this app). When the flagged set
        // does not include the default, this stays false on purpose: the
        // coordinator combines it with the bridge state for the user-facing one.
        updateMuteState()
        print("[AudioMuteController] mute flag=\(muted) devices=\(flaggedDevices.sorted())")
    }

    /// The default input as a mute target, empty if there is none.
    private func defaultInputTarget() -> Set<AudioObjectID> {
        refreshDefaultInputDevice()
        guard defaultInputDeviceID != kAudioObjectUnknown else {
            print("[AudioMuteController] No input device available")
            return []
        }
        return [defaultInputDeviceID]
    }

    /// Set/clear the flag on one device. Returns whether the device now carries
    /// the requested state (false = the device cannot be flagged at all, which
    /// the caller must treat as "still audible").
    @discardableResult
    private func applyFlag(_ muted: Bool, to device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Not every input exposes a mute flag (some Bluetooth routes do not).
        // Say so loudly: this is the one failure that leaves the user audible
        // while believing they are muted.
        guard AudioObjectHasProperty(device, &propertyAddress) else {
            print("[AudioMuteController] WARNING: device \(device) (\(name(of: device))) has no mute property; CANNOT mute it")
            return false
        }

        var muteValue: UInt32 = muted ? 1 : 0
        let result = AudioObjectSetPropertyData(
            device,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &muteValue
        )

        guard result == noErr else {
            print("[AudioMuteController] Failed to set mute on \(device) (\(name(of: device))): \(result)")
            return false
        }
        return true
    }

    /// Human-readable name for a device, for logging.
    private func name(of device: AudioObjectID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &propertyAddress, 0, nil,
                                         &propertySize, &name) == noErr,
              let cfName = name?.takeRetainedValue() else { return "?" }
        return cfName as String
    }

    /// Refresh the current mute state from the device.
    func refreshMuteState() {
        updateMuteState()
    }

    // MARK: - Private Methods - Device Management

    private func refreshDefaultInputDevice() {
        // Get the default input device ID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioObjectID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)

        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        if result == noErr && deviceID != kAudioObjectUnknown {
            // Remove listener from old device
            if defaultInputDeviceID != kAudioObjectUnknown {
                removeMuteChangeListener()
            }

            defaultInputDeviceID = deviceID
            updateDeviceName()
            checkMuteSupport()
            updateMuteState()
            setupMuteChangeListener()
            // Guarded: setMute() re-resolves the device on every call, and an
            // unconditional assignment would emit a change on each mute.
            let changed = self.deviceID != deviceID
            if changed { self.deviceID = deviceID }

            // Only on change: every setMute() lands here, and this log is the
            // main diagnostic trail for route problems — repeating the same
            // device on each mute buries the actual transitions.
            if changed {
                print("[AudioMuteController] Default input device: \(name(of: deviceID)) (ID: \(deviceID))")
            }
        } else {
            defaultInputDeviceID = kAudioObjectUnknown
            if self.deviceID != kAudioObjectUnknown { self.deviceID = kAudioObjectUnknown }
            DispatchQueue.main.async {
                self.inputDeviceName = "No Input Device"
                self.supportsMute = false
            }
        }
    }

    private func updateDeviceName() {
        guard defaultInputDeviceID != kAudioObjectUnknown else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let result = AudioObjectGetPropertyData(
            defaultInputDeviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &name
        )

        DispatchQueue.main.async {
            if result == noErr, let cfName = name?.takeRetainedValue() {
                self.inputDeviceName = cfName as String
            } else {
                self.inputDeviceName = "Unknown Device"
            }
        }
    }

    private func checkMuteSupport() {
        guard defaultInputDeviceID != kAudioObjectUnknown else {
            DispatchQueue.main.async {
                self.supportsMute = false
            }
            return
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let hasProperty = AudioObjectHasProperty(defaultInputDeviceID, &propertyAddress)

        DispatchQueue.main.async {
            self.supportsMute = hasProperty
        }

        if !hasProperty {
            print("[AudioMuteController] Warning: Device does not support mute property")
        }
    }

    private func updateMuteState() {
        guard defaultInputDeviceID != kAudioObjectUnknown else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if property exists
        guard AudioObjectHasProperty(defaultInputDeviceID, &propertyAddress) else {
            return
        }

        var muteValue: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let result = AudioObjectGetPropertyData(
            defaultInputDeviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &muteValue
        )

        if result == noErr {
            DispatchQueue.main.async {
                self.isMuted = muteValue != 0
            }
        }
    }

    // MARK: - Private Methods - Property Listeners

    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        deviceChangeListenerBlock = { [weak self] (_, _) in
            DispatchQueue.main.async {
                self?.refreshDefaultInputDevice()
            }
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            nil,
            deviceChangeListenerBlock!
        )
    }

    private func setupMuteChangeListener() {
        guard defaultInputDeviceID != kAudioObjectUnknown else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if device supports this property
        guard AudioObjectHasProperty(defaultInputDeviceID, &propertyAddress) else {
            return
        }

        muteChangeListenerBlock = { [weak self] (_, _) in
            DispatchQueue.main.async {
                self?.updateMuteState()
            }
        }

        AudioObjectAddPropertyListenerBlock(
            defaultInputDeviceID,
            &propertyAddress,
            nil,
            muteChangeListenerBlock!
        )
    }

    private func removeMuteChangeListener() {
        guard let block = muteChangeListenerBlock,
              defaultInputDeviceID != kAudioObjectUnknown else {
            return
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            defaultInputDeviceID,
            &propertyAddress,
            nil,
            block
        )

        muteChangeListenerBlock = nil
    }

    private func removeListeners() {
        // Remove device change listener
        if let block = deviceChangeListenerBlock {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                nil,
                block
            )

            deviceChangeListenerBlock = nil
        }

        // Remove mute change listener
        removeMuteChangeListener()
    }
}
