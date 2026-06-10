//
//  BannerKiller.swift
//  PodsMute
//
//  Dismisses the system "Microphone On/Off" banner via the Accessibility
//  API. The banner (com.apple.MuteControlUserNotifications, posted by
//  cloudpaird) bypasses Focus and notification preferences, so the only
//  way to remove it is to close it right after it appears.
//
//  We know the exact moment it shows up: the mute gesture handler fires
//  at the same time, so the hunt runs in a short burst after each press.
//

import Cocoa
import ApplicationServices

/// Hunts the Notification Center banner that the mute gesture produces
/// and dismisses it through its AX close action.
final class BannerKiller {

    // MARK: - Properties

    /// Verbose AX tree dump while hunting (recon mode for development).
    var reconMode = true

    private var huntTimer: Timer?
    private var huntDeadline = Date.distantPast
    private var huntStartedAt = Date.distantPast
    private var loggedNodes = Set<String>()

    // Self-check: measure when the banner actually leaves the AX tree.
    private var bannerPresentThisScan = false
    private var killedAt: Date?
    private var goneLogged = false

    // Off-screen window relocation state.
    private var movedWindow: AXUIElement?
    private var originalWindowPos: CGPoint?
    private var offscreenLogged = false

    private let ncBundleID = "com.apple.notificationcenterui"

    // Action descriptions that dismiss a banner (EN/ES), lowercase.
    private let closeDescriptions = ["close", "clear", "cerrar", "limpiar", "descartar", "dismiss"]
    // Never press these (they would toggle the mute state back).
    private let forbiddenDescriptions = ["turn on", "turn off", "activar", "desactivar"]

    // MARK: - Public Methods

    /// Ask for Accessibility trust (shows the system prompt when missing).
    func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        print("[BannerKiller] accessibility trusted: \(trusted)")
    }

    /// Start a hunt burst: scan every 50ms for 2.5s and dismiss on sight.
    func huntBanner() {
        guard AXIsProcessTrusted() else {
            print("[BannerKiller] not trusted for Accessibility - skipping hunt")
            return
        }

        huntStartedAt = Date()
        huntDeadline = huntStartedAt.addingTimeInterval(2.0)
        loggedNodes.removeAll()
        killedAt = nil
        goneLogged = false

        // Scan immediately - the banner is often already present by the time
        // the gesture handler runs, so waiting a tick only adds latency.
        scanOnce()

        guard huntTimer == nil else { return }
        huntTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if Date() > self.huntDeadline {
                self.restoreWindowIfNeeded()  // safety: never leave NC off-screen
                timer.invalidate()
                self.huntTimer = nil
                return
            }
            self.scanOnce()

            // Once killed, keep scanning until the banner leaves the AX tree,
            // so we can measure how long it actually stays visible.
            if let killed = self.killedAt, !self.bannerPresentThisScan, !self.goneLogged {
                self.goneLogged = true
                let goneMs = Int(Date().timeIntervalSince(killed) * 1000)
                print("[BannerKiller] banner GONE from AX tree (+\(goneMs)ms after kill)")
                self.restoreWindowIfNeeded()
                timer.invalidate()
                self.huntTimer = nil
            }
        }
    }

    // MARK: - Private Methods - Scanning

    private func scanOnce() {
        bannerPresentThisScan = false
        guard let nc = NSRunningApplication
            .runningApplications(withBundleIdentifier: ncBundleID).first else { return }

        let app = AXUIElementCreateApplication(nc.processIdentifier)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let windows = winsRef as? [AXUIElement] else { return }

        for window in windows {
            bannerInWindow = false
            walk(window, depth: 0, path: "win")
            // If this NC window hosts the banner, shove it off-screen so the
            // banner is not visible (and not captured) while it lives.
            if bannerInWindow { moveWindowOffscreen(window) }
        }
    }

    /// Whether the window currently being walked contains the banner.
    private var bannerInWindow = false

    private func moveWindowOffscreen(_ window: AXUIElement) {
        // Record the original position once, then move far off-screen.
        if movedWindow == nil {
            var posRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
               let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID() {
                var p = CGPoint.zero
                AXValueGetValue(posVal as! AXValue, .cgPoint, &p)
                originalWindowPos = p
            }
            movedWindow = window
        }

        var offscreen = CGPoint(x: -50_000, y: -50_000)
        guard let value = AXValueCreate(.cgPoint, &offscreen) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        if !offscreenLogged {
            offscreenLogged = true
            let ms = Int(Date().timeIntervalSince(huntStartedAt) * 1000)
            print("[BannerKiller] move NC window off-screen -> \(result == .success ? "OK" : "err \(result.rawValue)") (+\(ms)ms)")
        }
    }

    private func restoreWindowIfNeeded() {
        guard let window = movedWindow, let orig = originalWindowPos else {
            movedWindow = nil; originalWindowPos = nil; return
        }
        var p = orig
        if let value = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        movedWindow = nil
        originalWindowPos = nil
        offscreenLogged = false
    }

    private func walk(_ element: AXUIElement, depth: Int, path: String) {
        guard depth < 10 else { return }

        let role = stringAttr(element, kAXRoleAttribute) ?? "?"
        let subrole = stringAttr(element, kAXSubroleAttribute) ?? ""
        let title = stringAttr(element, kAXTitleAttribute) ?? ""
        let desc = stringAttr(element, kAXDescriptionAttribute) ?? ""
        let actions = actionInfo(element)

        let isInteresting = !subrole.isEmpty || !title.isEmpty || !desc.isEmpty || !actions.isEmpty

        if reconMode && isInteresting {
            let key = "\(path)|\(role)|\(subrole)|\(title)|\(desc)|\(actions.map(\.0).joined())"
            if !loggedNodes.contains(key) {
                loggedNodes.insert(key)
                // AX action names embed newlines (Name:X\nTarget:Y\n...); flatten them.
                let actionsStr = actions.map { "\(clean($0.0))('\(clean($0.1))')" }.joined(separator: ",")
                print("[BannerKiller] \(path) role=\(role) sub=\(subrole) title='\(title)' desc='\(clean(desc))' actions=[\(actionsStr)]")
            }
        }

        // A banner element advertises a notification-style subrole.
        if subrole.hasPrefix("AXNotificationCenter") {
            bannerPresentThisScan = true
            bannerInWindow = true
            tryDismiss(element, subrole: subrole, actions: actions)
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for (i, child) in children.enumerated() {
                walk(child, depth: depth + 1, path: "\(path).\(i)")
            }
        }
    }

    // MARK: - Private Methods - Dismissal

    private func tryDismiss(_ element: AXUIElement, subrole: String, actions: [(String, String)]) {
        for (name, description) in actions {
            let d = description.lowercased()
            if forbiddenDescriptions.contains(where: { d.contains($0) }) { continue }

            let isCloseByDesc = closeDescriptions.contains(where: { d.contains($0) })
            let isCloseByName = name == "AXCancel"

            if isCloseByDesc || isCloseByName || name.lowercased().contains("close") {
                let result = AXUIElementPerformAction(element, name as CFString)
                let latencyMs = Int(Date().timeIntervalSince(huntStartedAt) * 1000)
                print("[BannerKiller] KILL via \(clean(name))('\(clean(description))') -> \(result == .success ? "OK" : "err \(result.rawValue)") (+\(latencyMs)ms)")
                if result == .success {
                    if killedAt == nil { killedAt = Date() }
                    return
                }
            }
        }
    }

    // MARK: - Private Methods - AX Helpers

    /// Flatten embedded newlines/tabs so multi-line AX strings log on one line.
    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: " ")
    }

    private func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Returns (actionName, actionDescription) pairs for an element.
    private func actionInfo(_ element: AXUIElement) -> [(String, String)] {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return [] }
        return names.map { name in
            var descRef: CFString?
            AXUIElementCopyActionDescription(element, name as CFString, &descRef)
            return (name, (descRef as String?) ?? "")
        }
    }
}
