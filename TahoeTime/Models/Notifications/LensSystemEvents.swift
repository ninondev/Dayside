// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

/// Owns observer tokens explicitly; shutdown releases only this feature's subscriptions.
@MainActor
final class LensSystemEvents {
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    private var distributedToken: (any NSObjectProtocol)?
    var count: Int { tokens.count + (distributedToken == nil ? 0 : 1) }

    init(changeName: Notification.Name, onChange: @escaping @MainActor () -> Void) {
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
            tokens.append((.default, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
        tokens.append((workspace, wake))
        distributedToken = DistributedNotificationCenter.default().addObserver(forName: changeName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    isolated deinit { invalidate() }

    func invalidate() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        if let distributedToken { DistributedNotificationCenter.default().removeObserver(distributedToken) }
        distributedToken = nil
    }
}
