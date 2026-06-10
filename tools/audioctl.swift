// audioctl - tiny CoreAudio CLI for the PodsMute spike.
// Usage:
//   audioctl list                     # list input-capable devices
//   audioctl set-input <name-substr>  # set default input device
//   audioctl mute <on|off|status>     # mute state of default input
import CoreAudio
import Foundation

func getProp<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                _ value: inout T) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
}

func setProp<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                _ scope: AudioObjectPropertyScope, _ value: inout T) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(object, &addr, 0, nil,
                                      UInt32(MemoryLayout<T>.size), &value) == noErr
}

func hasProp(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    return AudioObjectHasProperty(object, &addr)
}

func deviceName(_ id: AudioObjectID) -> String {
    var name: Unmanaged<CFString>?
    guard getProp(id, kAudioDevicePropertyDeviceNameCFString, kAudioObjectPropertyScopeGlobal, &name),
          let cf = name?.takeRetainedValue() else { return "?" }
    return cf as String
}

func inputChannels(_ id: AudioObjectID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioObjectPropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func defaultInput() -> AudioObjectID {
    var id: AudioObjectID = kAudioObjectUnknown
    _ = getProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                kAudioObjectPropertyScopeGlobal, &id)
    return id
}

func muteInfo(_ id: AudioObjectID) -> String {
    guard hasProp(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput) else { return "mute:unsupported" }
    var v: UInt32 = 0
    _ = getProp(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, &v)
    return v != 0 ? "mute:ON" : "mute:off"
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "list"

switch cmd {
case "list":
    let def = defaultInput()
    for id in allDevices() where inputChannels(id) > 0 {
        let mark = id == def ? "*" : " "
        print("\(mark) [\(id)] \(deviceName(id))  ch:\(inputChannels(id))  \(muteInfo(id))")
    }
case "set-input":
    guard args.count > 2 else { print("usage: audioctl set-input <name-substr>"); exit(1) }
    let needle = args[2].lowercased()
    guard let target = allDevices().first(where: {
        inputChannels($0) > 0 && deviceName($0).lowercased().contains(needle)
    }) else { print("no input device matching '\(args[2])'"); exit(1) }
    var id = target
    if setProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
               kAudioObjectPropertyScopeGlobal, &id) {
        print("default input -> [\(target)] \(deviceName(target))")
    } else { print("failed to set default input"); exit(1) }
case "mute":
    let dev = defaultInput()
    let sub = args.count > 2 ? args[2] : "status"
    if sub == "status" { print("[\(dev)] \(deviceName(dev))  \(muteInfo(dev))"); exit(0) }
    guard hasProp(dev, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput) else {
        print("[\(dev)] \(deviceName(dev)) does not support mute property"); exit(1)
    }
    var v: UInt32 = (sub == "on") ? 1 : 0
    if setProp(dev, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, &v) {
        print("[\(dev)] \(deviceName(dev))  \(muteInfo(dev))")
    } else { print("failed to set mute"); exit(1) }
case "running":
    let dev = defaultInput()
    var v: UInt32 = 0
    _ = getProp(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, &v)
    print("[\(dev)] \(deviceName(dev))  capturing:\(v != 0 ? "YES" : "no")")
default:
    print("usage: audioctl [list | set-input <name-substr> | mute <on|off|status> | running]")
}
