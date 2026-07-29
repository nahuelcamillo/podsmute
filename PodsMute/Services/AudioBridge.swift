//
//  AudioBridge.swift
//  PodsMute
//
//  Bridges the real microphone (e.g. AirPods) to a virtual output device
//  (BlackHole) so meeting apps can capture from the virtual device. When
//  muted, the bridge simply stops forwarding audio, so the virtual device
//  delivers silence WITHOUT being flagged as muted — meeting apps (Meet)
//  don't detect a "system mute" and never auto-mute.
//
//  Mic (AirPods) ──capture──▶ [AudioBridge] ──play──▶ BlackHole ──▶ Meet
//
//  Two AVAudioEngines are used because input and output are different HAL
//  devices: a capture engine pinned to the mic, a playback engine pinned to
//  BlackHole, with format conversion in between.
//

import AVFoundation
import CoreAudio

final class AudioBridge {

    static let shared = AudioBridge()

    /// Substring identifying the virtual loopback driver in device names.
    static let virtualDeviceNeedle = "blackhole"

    /// Whether the virtual device (BlackHole) is installed right now.
    static var isInstalled: Bool { virtualDeviceID != nil }

    /// The virtual device's ID, if installed. BlackHole is a single loopback
    /// device, so this same ID shows up on a meeting app's capture side.
    static var virtualDeviceID: AudioDeviceID? {
        deviceID(matching: virtualDeviceNeedle, input: false)
    }

    // MARK: - State

    /// When true, audio is not forwarded → the virtual device gets silence.
    /// Owned by MuteCoordinator; survives stop()/start() cycles on purpose.
    var muted = false

    private(set) var running = false

    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var restartPending = false

    // Deferred-start retry: the capture device's format can be invalid
    // (0 Hz / 0 ch) for a beat while AirPods negotiate HFP at call start.
    private var startRetries = 0
    private let maxStartRetries = 6   // ~3s at 0.5s spacing, covers the HFP handoff
    private var startGeneration = 0   // bumped on stop() to cancel pending retries

    private init() {
        // Engines renegotiate I/O when devices change (AirPods dropping
        // mid-call turns the default input into the built-in mic); restart so
        // the bridge follows the new device instead of going silent.
        NotificationCenter.default.addObserver(
            self, selector: #selector(engineConfigurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange, object: nil)
    }

    // MARK: - Public

    /// Start bridging the default input device into the virtual device.
    @discardableResult
    func start() -> Bool {
        guard !running else { return true }

        guard let outDev = Self.virtualDeviceID else {
            print("[AudioBridge] virtual device (BlackHole) not installed"); return false
        }
        // Capturing the default input while it IS the virtual device would
        // feed the device back into itself.
        guard Self.defaultInputID() != outDev else {
            print("[AudioBridge] default input is the virtual device; not bridging"); return false
        }

        // The capture node's native format is invalid (0 Hz / 0 ch) for a beat
        // while the input renegotiates — typically AirPods switching to HFP the
        // instant a call opens the mic. installTap(format: nil) below would
        // throw an AVFAudio NSException (uncatchable from Swift) and abort the
        // app, so wait for a valid format and retry instead of tapping a
        // half-initialized node.
        let inFmt = captureEngine.inputNode.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            scheduleStartRetry(reason: "input not ready (\(Int(inFmt.sampleRate))Hz/\(inFmt.channelCount)ch)")
            return false
        }
        print("[AudioBridge] play dev=\(outDev) in=\(inFmt) (capture uses default input)")

        // Capture uses the default input device (the user's real mic). Only
        // the playback engine needs to be pinned to BlackHole.
        guard setDevice(playbackEngine, deviceID: outDev, scopeInput: false) else {
            print("[AudioBridge] failed to pin playback device"); return false
        }

        if player.engine == nil { playbackEngine.attach(player) }
        let outFmt = playbackEngine.outputNode.inputFormat(forBus: 0)
        outputFormat = outFmt
        playbackEngine.connect(player, to: playbackEngine.outputNode, format: outFmt)

        guard outFmt.sampleRate > 0 else {
            print("[AudioBridge] invalid output format \(outFmt)"); return false
        }
        print("[AudioBridge] out=\(outFmt)")

        // Tap with the node's NATIVE format (nil) to avoid a format-mismatch
        // crash; the converter is built lazily from the actual buffer format.
        captureEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.forward(buffer)
        }

        do {
            try playbackEngine.start()
            player.play()
            try captureEngine.start()
            running = true
            let wasDeferred = startRetries > 0
            startRetries = 0
            print("[AudioBridge] running (muted=\(muted))")
            // A deferred start succeeds after the coordinator already fell back
            // synchronously; tell it to adopt stealth and re-apply the mute.
            if wasDeferred {
                NotificationCenter.default.post(name: .podsMuteBridgeDidStart, object: self)
            }
            return true
        } catch {
            print("[AudioBridge] start failed: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        startGeneration &+= 1   // cancel any pending deferred-start retry
        startRetries = 0
        guard running else { return }
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        player.stop()
        playbackEngine.stop()
        converter = nil
        outputFormat = nil
        running = false
        print("[AudioBridge] stopped")
    }

    /// Retry start() shortly: the input device was not ready (e.g. AirPods
    /// mid-HFP-handoff). Bounded so a permanently invalid input (no mic
    /// permission, no input device) falls back to classic flag-mute instead
    /// of looping forever.
    private func scheduleStartRetry(reason: String) {
        guard startRetries < maxStartRetries else {
            startRetries = 0
            print("[AudioBridge] \(reason); gave up, classic flag-mute in effect")
            return
        }
        startRetries += 1
        let gen = startGeneration
        print("[AudioBridge] \(reason); retry \(startRetries)/\(maxStartRetries) in 0.5s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, !self.running, self.startGeneration == gen else { return }
            self.start()
        }
    }

    // MARK: - Device changes

    @objc private func engineConfigurationChanged(_ note: Notification) {
        guard let engine = note.object as? AVAudioEngine,
              engine === captureEngine || engine === playbackEngine else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.running, !self.restartPending else { return }
            self.restartPending = true
            print("[AudioBridge] engine configuration changed; restarting")
            // Let the HAL settle before rebuilding on the new device.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.restartPending = false
                self.stop()
                self.start()
            }
        }
    }

    // MARK: - Forwarding

    private func forward(_ input: AVAudioPCMBuffer) {
        guard !muted, let outFmt = outputFormat else { return }

        // Build (or rebuild) the converter lazily from the real input format.
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outFmt)
        }
        guard let converter = converter else { return }

        let ratio = outFmt.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error = error {
            print("[AudioBridge] convert error: \(error)")
            return
        }
        player.scheduleBuffer(output, completionHandler: nil)
    }

    // MARK: - CoreAudio helpers

    /// Pin an AVAudioEngine's I/O unit to a specific HAL device (modern API).
    private func setDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID, scopeInput: Bool) -> Bool {
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
            return true
        } catch {
            print("[AudioBridge] setDeviceID(\(deviceID)) failed: \(error)")
            return false
        }
    }

    /// The system default input device, or kAudioObjectUnknown.
    static func defaultInputID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// Find a device ID whose name contains `needle`, with input or output channels.
    static func deviceID(matching needle: String, input: Bool) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return nil }

        let want = needle.lowercased()
        for id in ids {
            guard channelCount(id, input: input) > 0 else { continue }
            guard let name = deviceName(id)?.lowercased(), name.contains(want) else { continue }
            return id
        }
        return nil
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func channelCount(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
