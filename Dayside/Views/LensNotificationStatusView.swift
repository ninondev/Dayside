// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct LensNotificationStatusView: View {
    let notifications: ScopedLensNotifications
    let requestPermission: () async -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch notifications.access {
            case .notDetermined:
                Button("允许系统通知") { Task { await requestPermission() } }
            case .denied:
                Text("系统未允许通知，界面仍可使用。可在系统设置中允许 Dayside 通知。")
                    .appFont(.caption).foregroundStyle(.readableSecondary)
            case .authorized:
                EmptyView()
            }
            if notifications.failed {
                ErrorLine(Text("提醒未能安排，请稍后重试。")).appFont(.caption)
                Button("重试安排提醒", action: retry)
                    .help(Text("重新安排没排上的提醒"))
                    .accessibilityHint(Text("重新安排没排上的提醒"))
            }
        }
    }
}

struct LensNotificationValue: ViewModifier {
    let access: LensNotificationAccess

    @ViewBuilder func body(content: Content) -> some View {
        if access == .authorized {
            content.accessibilityValue(Text("已允许系统通知"))
        } else {
            content
        }
    }
}
