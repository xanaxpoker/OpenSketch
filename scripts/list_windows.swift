// usage: swift list_windows.swift <pid>  — prints on-screen window IDs, layer, size and title for that PID
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in info where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String]!, "layer=\(w[kCGWindowLayer as String]!)", "onscreen=\(w[kCGWindowIsOnscreen as String] ?? false)",
          "\(b["Width"] ?? 0)x\(b["Height"] ?? 0)", "title=\(w[kCGWindowName as String] ?? "")")
}
