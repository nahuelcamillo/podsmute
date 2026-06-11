//
//  HotKeyService.swift
//  PodsMute
//
//  Global keyboard shortcuts via Carbon RegisterEventHotKey. This is the
//  classic system-wide hotkey API: it works from any app, consumes the key
//  combo, and needs no Accessibility permission (unlike NSEvent global
//  monitors). Lets the user mute and toggle the cue without the menu bar
//  icon, which can be hidden behind the notch on a full menu bar.
//

import Carbon.HIToolbox
import Cocoa

/// Carbon modifier masks, re-exported for readable call sites.
enum HotKeyMod {
    static let command = UInt32(cmdKey)
    static let option  = UInt32(optionKey)
    static let shift   = UInt32(shiftKey)
    static let control = UInt32(controlKey)
}

/// Common ANSI virtual key codes used by this app.
enum HotKeyCode {
    static let m: UInt32 = 46  // kVK_ANSI_M
    static let s: UInt32 = 1   // kVK_ANSI_S
}

final class HotKeyService {

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    // 'PMUT' as an OSType signature for our hotkeys.
    private let signature: OSType = 0x504D5554

    /// Install the shared Carbon event handler. Call once before register().
    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData = userData, let event = event else { return noErr }
            let service = Unmanaged<HotKeyService>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { service.handlers[hkID.id]?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// Register a global hotkey. modifiers is a Carbon mask (HotKeyMod).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        handlers[id] = handler

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
            return true
        } else {
            print("[HotKey] register failed (code=\(keyCode) mods=\(modifiers)): \(status)")
            handlers[id] = nil
            return false
        }
    }

    deinit {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    }
}
