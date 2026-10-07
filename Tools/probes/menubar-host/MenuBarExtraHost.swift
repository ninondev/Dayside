// SPDX-License-Identifier: GPL-3.0-only
// 6.8 宿主探针 B：SwiftUI MenuBarExtra(.window)，面板同样是一个 Text。不开面板、不轮询。
import SwiftUI

@main
struct Probe: App {
    init() { FileHandle.standardOutput.write("READY\n".data(using: .utf8)!) }
    var body: some Scene {
        MenuBarExtra("12:34 · 21:34") {
            Text("hello").padding().frame(width: 320, height: 200)
        }.menuBarExtraStyle(.window)
    }
}
