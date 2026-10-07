// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import TahoeTime

@Suite(.serialized)
@MainActor
struct LateNotificationValueTests {
    @Test(arguments: [InterfaceLanguage.zhHans, .en, .ru])
    func allowedValueReachesBothReminderToggles(language: InterfaceLanguage) async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "late-notification-value")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = language
        let timer = TimerStore(defaults: defaults, notificationClient: LateNotificationClient(.authorized),
                               observeSystemEvents: false, runtimeEnabled: false)
        let dst = DSTWatchStore(defaults: defaults, notificationClient: LateNotificationClient(.authorized),
                                factsProvider: { _, _ in [] }, observeSystemEvents: false)
        timer.setNotificationsEnabled(true)
        dst.setEnabled(true)
        await timer.notifications.refreshAccess()
        await dst.notifications.refreshAccess()
        let content = VStack {
            Toggle("到期通知", isOn: .constant(true)).accessibilityIdentifier("late-unmodified-toggle")
            TimerLensView(store: timer)
            DSTWatchLensView(store: dst)
        }.environment(model).environment(model.core).environment(\.locale, model.uiLocale)
        let nodes = try await nodes(in: content)
        let expected = L10n.string("已允许系统通知", locale: model.uiLocale)
        for key in ["到期通知", "已保存地点的时钟调整提醒"] {
            let label = L10n.string(key, locale: model.uiLocale)
            let toggle = try #require(nodes.first { node in
                (attribute(node, "accessibilityLabel") as? String == label
                 || attribute(node, "accessibilityTitle") as? String == label)
                && attribute(node, "accessibilityRole") as? String == "AXCheckBox"
                && attribute(node, "accessibilityIdentifier") as? String != "late-unmodified-toggle"
            })
            #expect(attribute(toggle, "accessibilityValueDescription") as? String == expected)
            #expect((attribute(toggle, "accessibilityValue") as? NSNumber)?.intValue == 1)
        }
        let control = try #require(nodes.first { attribute($0, "accessibilityIdentifier") as? String == "late-unmodified-toggle" })
        #expect(attribute(control, "accessibilityValueDescription") as? String != expected)
        #expect(!nodes.contains { node in
            attribute(node, "accessibilityRole") as? String == "AXStaticText"
            && attribute(node, "accessibilityValue") as? String == expected
        })
        dst.setEnabled(false)
    }

    @Test(arguments: [LensNotificationAccess.denied, .notDetermined])
    func unavailableStatesKeepVisibleGuidanceAndToggleValue(access: LensNotificationAccess) async throws {
        let notifications = ScopedLensNotifications(prefix: "late-status.", client: LateNotificationClient(access))
        await notifications.refreshAccess()
        let content = VStack {
            Toggle("到期通知", isOn: .constant(true)).modifier(LensNotificationValue(access: access))
            LensNotificationStatusView(notifications: notifications, requestPermission: {}, retry: {})
        }.environment(\.locale, Locale(identifier: "zh-Hans"))
        let nodes = try await nodes(in: content)
        let toggle = try #require(nodes.first { attribute($0, "accessibilityRole") as? String == "AXCheckBox" })
        #expect(attribute(toggle, "accessibilityValueDescription") as? String != "通知已允许")
        #expect((attribute(toggle, "accessibilityValue") as? NSNumber)?.intValue == 1)
        let expected = access == .denied
            ? "系统未允许通知，界面仍可使用。可在系统设置中允许 Dayside 通知。" : "允许系统通知"
        let localized = L10n.string(expected, locale: Locale(identifier: "zh-Hans"))
        #expect(nodes.contains { node in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                attribute(node, $0) as? String == localized
            }
        })
    }

    private func nodes<Content: View>(in content: Content) async throws -> [NSObject] {
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1_600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        TestHostWindowPolicy.prepare(window)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let previous = attribute(NSApp, "accessibilityEnhancedUserInterface") as? Bool ?? false
        enhance(true)
        defer { enhance(previous) }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        var result: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        func walk(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in attribute(object, "accessibilityChildren") as? [NSObject] ?? [] { walk(child) }
        }
        walk(window)
        return result
    }

    private func attribute(_ object: NSObject, _ key: String) -> Any? {
        let alternate = "is" + key.prefix(1).uppercased() + key.dropFirst()
        if object.responds(to: NSSelectorFromString(key)) || object.responds(to: NSSelectorFromString(alternate)) {
            let value = object.value(forKey: key)
            if key != "accessibilityChildren" || !((value as? [Any])?.isEmpty ?? true) { return value }
        }
        let legacy = ["accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole",
                      "accessibilityLabel": "AXDescription", "accessibilityTitle": "AXTitle",
                      "accessibilityValue": "AXValue", "accessibilityValueDescription": "AXValueDescription", "accessibilityIdentifier": "AXIdentifier",
                      "accessibilityEnhancedUserInterface": "AXEnhancedUserInterface"][key]
        guard let legacy, object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: legacy)?.takeUnretainedValue()
    }

    private func enhance(_ value: Bool) {
        if NSApp.responds(to: NSSelectorFromString("setAccessibilityEnhancedUserInterface:")) {
            NSApp.setValue(value, forKey: "accessibilityEnhancedUserInterface")
        }
        if NSApp.responds(to: NSSelectorFromString("accessibilitySetValue:forAttribute:")) {
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                              with: NSNumber(value: value), with: "AXEnhancedUserInterface")
        }
    }
}

@MainActor
private final class LateNotificationClient: LensNotificationClient {
    let access: LensNotificationAccess
    init(_ access: LensNotificationAccess) { self.access = access }
    func authorization() async -> LensNotificationAccess { access }
    func requestAuthorization() async throws -> Bool { access == .authorized }
    func pendingIdentifiers() async -> [String] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: LensNotificationRequest) async throws {}
    func removePending(_ identifiers: [String]) {}
    func removeDelivered(_ identifiers: [String]) {}
}
