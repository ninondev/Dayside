// SPDX-License-Identifier: GPL-3.0-only
// 打印指定进程的屏上窗口：windowID 宽 高 层级。只读，不点任何东西。
// 参数是进程名（旧用法）或 `pid:<数字>`：按 pid 找才不会拿到同名的另一份副本的窗口
// 多份 App 副本同时运行时，必须按进程找窗口，避免截图取到另一份副本。
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DaysideFeaturePreview"
let wantedPID: Int? = wanted.hasPrefix("pid:") ? Int(wanted.dropFirst(4)) : nil
let options: CGWindowListOption = CommandLine.arguments.contains("--all-spaces")
    ? [.excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
var rows: [(Int, Double, Double, Int, Double, Double)] = []
for info in list {
    if let pid = wantedPID {
        guard (info[kCGWindowOwnerPID as String] as? Int) == pid else { continue }
    } else {
        let appName = info[kCGWindowOwnerName as String] as? String ?? ""
        guard appName == wanted else { continue }
    }
    let id = info[kCGWindowNumber as String] as? Int ?? -1
    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let w = bounds["Width"] as? Double ?? 0
    let h = bounds["Height"] as? Double ?? 0
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    let x = bounds["X"] as? Double ?? 0
    let y = bounds["Y"] as? Double ?? 0
    rows.append((id, w, h, layer, x, y))
}
// 最大的窗口排第一：附着的 sheet / 确认框也是同一 pid 的窗口，不能让它抢到第一行。末尾附 x y 供区域截图。
for (id, w, h, layer, x, y) in rows.sorted(by: { $0.1 * $0.2 > $1.1 * $1.2 }) {
    print("\(id) \(Int(w)) \(Int(h)) \(layer) \(Int(x)) \(Int(y))")
}
