// winls - one-shot dump of all on-screen windows (owner, pid, layer, bounds).
import CoreGraphics
import Foundation

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] else { exit(1) }

for w in list {
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    var rect = ""
    if let b = w[kCGWindowBounds as String] as? [String: Any] {
        rect = "(\(b["X"] ?? "?"),\(b["Y"] ?? "?") \(b["Width"] ?? "?")x\(b["Height"] ?? "?"))"
    }
    let name = w[kCGWindowName as String] as? String ?? ""
    print("#\(num) owner=\(owner) pid=\(pid) layer=\(layer) \(rect) \(name)")
}
