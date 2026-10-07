// SPDX-License-Identifier: GPL-3.0-only
// 6.8 宿主探针 A：纯 AppKit NSStatusItem + NSPopover(装一个 SwiftUI Text 以便与 B 对等)。不开面板、不轮询。
import AppKit
import SwiftUI

final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "12:34 · 21:34"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.contentViewController = NSHostingController(rootView: Text("hello").padding().frame(width: 320, height: 200))
        popover.behavior = .transient
        FileHandle.standardOutput.write("READY\n".data(using: .utf8)!)
    }
    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) } else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
