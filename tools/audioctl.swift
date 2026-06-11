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
case "inputvol":
    // Get/set input volume scalar (0...1). Lets us compare "volume 0" vs the
    // mute flag and see which one Chrome reports as track.muted.
    let dev = defaultInput()
    let sub = args.count > 2 ? args[2] : "get"
    let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
    func volAddr(_ el: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioObjectPropertyScopeInput, mElement: el)
    }
    if sub == "get" {
        for el in elements {
            var addr = volAddr(el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var v: Float32 = 0; var sz = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &v) == noErr {
                print("[\(dev)] \(deviceName(dev))  inputvol(el \(el)) = \(v)")
                exit(0)
            }
        }
        print("[\(dev)] \(deviceName(dev)) has no input volume scalar"); exit(1)
    } else {
        let target = Float32(max(0, min(1, Double(sub) ?? 0)))
        var setAny = false
        for el in elements {
            var addr = volAddr(el)
            guard AudioObjectHasProperty(dev, &addr) else { continue }
            var v = target
            if AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &v) == noErr {
                setAny = true
            }
        }
        if setAny { print("[\(dev)] \(deviceName(dev))  inputvol -> \(target)") }
        else { print("[\(dev)] could not set input volume (not settable)"); exit(1) }
    }
case "procs":
    // List CoreAudio process objects that are capturing, and WHICH devices
    // each one holds open (input scope). Validates the data the app uses to
    // decide whether an external capture bypasses the BlackHole bridge.
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { print("no process object list"); exit(1) }
    var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs) == noErr
    else { print("cannot read process object list"); exit(1) }

    func procDevices(_ obj: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                                           mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids
    }

    for obj in objs {
        var pid: pid_t = -1
        _ = getProp(obj, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid)
        var running: UInt32 = 0
        _ = getProp(obj, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal, &running)
        let inputDevs = procDevices(obj, scope: kAudioObjectPropertyScopeInput)
        let allDevs = procDevices(obj, scope: kAudioObjectPropertyScopeGlobal)
        guard running != 0 || !inputDevs.isEmpty else { continue }
        var name = "?"
        if pid > 0 {
            var buf = [CChar](repeating: 0, count: 1024)
            if proc_name(pid, &buf, UInt32(buf.count)) > 0 { name = String(cString: buf) }
        }
        let inputs = inputDevs.map { "[\($0)] \(deviceName($0))" }.joined(separator: ", ")
        let all = allDevs.map { "\($0)" }.joined(separator: ",")
        print("pid \(pid) (\(name))  capturing:\(running != 0 ? "YES" : "no")  inputDevs: \(inputs.isEmpty ? "-" : inputs)  allDevs: \(all)")
    }
default:
    print("usage: audioctl [list | set-input <name-substr> | mute <on|off|status> | running | inputvol [0..1] | procs]")
}
