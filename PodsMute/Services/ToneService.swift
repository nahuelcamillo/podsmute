//
//  ToneService.swift
//  PodsMute
//
//  Plays a distinctive synthesized cue on mute/unmute so the action is
//  recognizable by ear, without looking at the screen. This is OUR cue,
//  added on top of the system's (unchangeable) native tone.
//
//  Design: mute = low, descending pair ("closing"); unmute = high,
//  ascending pair ("opening"). Register + direction together make the two
//  unmistakable. Tones are generated as PCM, no audio files needed.
//

import AVFoundation

final class ToneService {

    static let shared = ToneService()
    private init() {}

    // MARK: - Properties

    // Created lazily on first use: touching AVAudioEngine during app launch
    // (especially from the LaunchAgent context) can block the main thread.
    private lazy var engine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var prepared = false
    private var stopTask: DispatchWorkItem?

    // Two notes per cue (Hz). Direction + register distinguish them.
    private let muteNotes: [Double]   = [523.25, 349.23]  // C5 -> F4, low & falling
    private let unmuteNotes: [Double] = [659.25, 987.77]  // E5 -> B5, high & rising

    private let noteDuration = 0.085
    private let gapDuration  = 0.035
    // Buffer peak amplitude. Headroom above the validated ~0.22 so the volume
    // slider can go louder; the configurable volume scales the mixer below.
    private let amplitude: Float = 0.5

    // MARK: - Public Methods

    /// Play the cue matching the resulting state, at the configured volume.
    func play(muted: Bool) {
        prepare()
        startIfNeeded()

        // Apply the user's volume (0...1) to the mixer output.
        engine.mainMixerNode.outputVolume = Float(AppSettings.shared.toneVolume)

        guard let buffer = makeBuffer(notes: muted ? muteNotes : unmuteNotes) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }

        scheduleStop()
    }

    // MARK: - Private Methods

    private func prepare() {
        guard !prepared else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        prepared = true
    }

    private func startIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("[ToneService] engine start failed: \(error)")
        }
    }

    /// Stop the output engine after a short idle period so the AirPods are not
    /// kept in an active audio mode while no cue is playing.
    private func scheduleStop() {
        stopTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.player.stop()
            self.engine.stop()
        }
        stopTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    /// Build a mono PCM buffer of the note sequence, with short fades to
    /// avoid clicks and a small silent gap between notes.
    private func makeBuffer(notes: [Double]) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let noteFrames = Int(sr * noteDuration)
        let gapFrames = Int(sr * gapDuration)
        let totalFrames = noteFrames * notes.count + gapFrames * max(0, notes.count - 1)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(totalFrames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalFrames)

        let fade = max(1, Int(sr * 0.008))
        var idx = 0
        for (n, freq) in notes.enumerated() {
            for i in 0..<noteFrames {
                let t = Double(i) / sr
                var sample = Float(sin(2.0 * .pi * freq * t)) * amplitude
                if i < fade {
                    sample *= Float(i) / Float(fade)
                } else if i >= noteFrames - fade {
                    sample *= Float(noteFrames - i) / Float(fade)
                }
                channel[idx] = sample
                idx += 1
            }
            if n < notes.count - 1 {
                for _ in 0..<gapFrames { channel[idx] = 0; idx += 1 }
            }
        }
        return buffer
    }
}
