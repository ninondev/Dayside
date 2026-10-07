// SPDX-License-Identifier: GPL-3.0-only
import AppIntents
import AppKit

@MainActor
final class TimeConversionService: NSObject {
    static let shared = TimeConversionService()
    @objc func convertTime(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard !ApplicationSession.isIsolated else { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty, text.utf8.count <= 2048 else { return }
        var components = URLComponents()
        components.scheme = "dayside"
        components.host = "convert"
        components.queryItems = [.init(name: "text", value: text)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
