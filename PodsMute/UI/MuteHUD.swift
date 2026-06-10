//
//  MuteHUD.swift
//  PodsMute
//
//  On-screen mute state indicator that is EXCLUDED from screen capture
//  (sharingType = .none), so meeting participants never see it while
//  the screen is being shared.
//

import Cocoa

/// Volume-bezel style HUD showing the microphone state.
///
/// The panel is invisible to ScreenCaptureKit/screen sharing because its
/// sharingType is .none (same mechanism password managers use).
final class MuteHUD {

    static let shared = MuteHUD()

    // MARK: - Properties

    private let panel: NSPanel
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideTask: DispatchWorkItem?

    private let hudSize = NSSize(width: 190, height: 190)

    // MARK: - Initialization

    private init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hudSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        // Invisible to screen recording / sharing.
        panel.sharingType = .none

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Blurred rounded background, like the system volume bezel.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: hudSize))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true

        iconView.frame = NSRect(x: 0, y: 58, width: hudSize.width, height: 96)
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(iconView)

        label.frame = NSRect(x: 0, y: 24, width: hudSize.width, height: 26)
        label.alignment = .center
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        effect.addSubview(label)

        panel.contentView = effect
    }

    // MARK: - Public Methods

    /// Show the HUD reflecting the mute state, then fade out.
    func show(muted: Bool) {
        let color: NSColor = muted ? .systemRed : .systemGreen
        let symbol = muted ? "mic.slash.fill" : "mic.fill"

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 72, weight: .medium)
                .applying(.init(paletteColors: [color]))
            iconView.image = image.withSymbolConfiguration(config)
        }
        label.stringValue = muted ? "Mic apagado" : "Mic encendido"
        label.textColor = color

        centerOnActiveScreen()

        hideTask?.cancel()
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()

        let task = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: task)
    }

    // MARK: - Private Methods

    private func centerOnActiveScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        // Horizontally centered, lower third - same spot as the volume bezel.
        let origin = NSPoint(
            x: frame.midX - hudSize.width / 2,
            y: frame.minY + frame.height * 0.18
        )
        panel.setFrameOrigin(origin)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }
}
