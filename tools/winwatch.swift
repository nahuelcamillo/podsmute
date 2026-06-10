// winwatch - prints every window that appears on screen, with its owner
// process. Used to identify which system process renders the
// "Microphone On/Off" banner. No special permissions needed for owner info.
import CoreGraphics
import Foundation

func snapshot() -> [Int: [String: Any]] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
    var out: [Int: [String: Any]] = [:]
    for w in list {
        if let num = w[kCGWindowNumber as String] as? Int { out[num] = w }
    }
    return out
}

var prev = snapshot()
FileHandle.standardError.write("watching for new windows...\n".data(using: .utf8)!)

while true {
    usleep(150_000)
    let cur = snapshot()
    for (num, w) in cur where prev[num] == nil {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        var rect = ""
        if let b = w[kCGWindowBounds as String] as? [String: Any] {
            rect = "(\(b["X"] ?? "?"),\(b["Y"] ?? "?") \(b["Width"] ?? "?")x\(b["Height"] ?? "?"))"
        }
        let name = w[kCGWindowName as String] as? String ?? ""
        print("NEW #\(num) owner=\(owner) pid=\(pid) layer=\(layer) \(rect) \(name)")
        fflush(stdout)
    }
    prev = cur
}
