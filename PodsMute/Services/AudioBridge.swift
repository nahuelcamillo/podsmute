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

    // MARK: - State

    /// When true, audio is not forwarded → the virtual device gets silence.
    var muted = false

    private(set) var running = false

    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // MARK: - Public

    /// Start bridging from the input device to the output device (by name match).
    /// - inputMatch: substring of the mic to capture (e.g. "airpods").
    /// - outputMatch: substring of the virtual output (e.g. "blackhole").
    @discardableResult
    func start(inputMatch: String, outputMatch: String) -> Bool {
        guard !running else { return true }

        guard let outDev = Self.deviceID(matching: outputMatch, input: false) else {
            print("[AudioBridge] output device matching '\(outputMatch)' not found"); return false
        }
        print("[AudioBridge] play dev=\(outDev) (capture uses default input)")

        // Capture uses the default input device (caller pins it to the mic via
        // audioctl). Only the playback engine needs to target BlackHole.
        guard setDevice(playbackEngine, deviceID: outDev, scopeInput: false) else {
            print("[AudioBridge] failed to pin playback device"); return false
        }

        playbackEngine.attach(player)
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
            print("[AudioBridge] running")
            return true
        } catch {
            print("[AudioBridge] start failed: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        guard running else { return }
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        player.stop()
        playbackEngine.stop()
        running = false
        print("[AudioBridge] stopped")
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
