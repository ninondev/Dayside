// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Testing
@testable import Dayside

@MainActor
struct FeatureNavigationTests {
    @Test func firstLaunchKeepsCalendarAsTheStartingPage() {
        let handle = TestDefaults.make(prefix: "dayside.navigation.first-launch")
        defer { handle.cleanup() }
        #expect(FeatureHub(defaults: handle.defaults).selection == .agenda)
    }

    @Test(arguments: FeatureSelection.allCases)
    func lastSelectedPageSurvivesRelaunch(page: FeatureSelection) throws {
        let (suite, cleanup) = TestDefaults.makeSuiteName(prefix: "dayside.navigation.relaunch")
        defer { cleanup() }
        do {
            let defaults = try #require(UserDefaults(suiteName: suite))
            let hub = FeatureHub(defaults: defaults)
            hub.selection = page
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let relaunched = FeatureHub(defaults: defaults)
        #expect(relaunched.selection == page)
    }

    @Test func invalidSavedPageKeepsCalendarAsTheStartingPage() {
        let handle = TestDefaults.make(prefix: "dayside.navigation.invalid")
        defer { handle.cleanup() }
        handle.defaults.set("removed-page", forKey: "dayside.tools.selection.v1")
        #expect(FeatureHub(defaults: handle.defaults).selection == .agenda)
        handle.defaults.set(42, forKey: "dayside.tools.selection.v1")
        #expect(FeatureHub(defaults: handle.defaults).selection == .agenda)
    }

    @Test func separateDefaultsSuitesKeepIndependentPages() {
        let first = TestDefaults.make(prefix: "dayside.navigation.first-suite")
        let second = TestDefaults.make(prefix: "dayside.navigation.second-suite")
        defer {
            first.cleanup()
            second.cleanup()
        }
        FeatureHub(defaults: first.defaults).selection = .travel
        #expect(FeatureHub(defaults: second.defaults).selection == .agenda)
        FeatureHub(defaults: second.defaults).selection = .markets
        #expect(FeatureHub(defaults: first.defaults).selection == .travel)
        #expect(FeatureHub(defaults: second.defaults).selection == .markets)
    }

    @Test(arguments: FeatureSelection.allCases)
    func explicitPageNavigationOverridesRememberedPage(page: FeatureSelection) {
        let handle = TestDefaults.make(prefix: "dayside.navigation.explicit")
        defer { handle.cleanup() }
        let original = FeatureHub(defaults: handle.defaults)
        original.selection = .sharing
        let relaunched = FeatureHub(defaults: handle.defaults)
        let model = AppModel(defaults: handle.defaults, migrate: false, applySystemIntegration: false)
        relaunched.attach(to: model)
        #expect(relaunched.handle(.init(action: "tools", arguments: ["feature": page.rawValue])))
        #expect(relaunched.selection == page)
        relaunched.selection = .markets
        #expect(relaunched.selection == .markets)
        #expect(relaunched.handle(.init(action: "convert", arguments: ["text": "14:00 UTC"])))
        #expect(relaunched.selection == .convert)
        #expect(relaunched.conversionText == "14:00 UTC")
    }

    @Test(arguments: [InterfaceLanguage.zhHans, .en])
    func restoredWorkspaceRendersTheLastPage(language: InterfaceLanguage) async throws {
        let handle = TestDefaults.make(prefix: "dayside.navigation.render")
        defer { handle.cleanup() }
        let original = FeatureHub(defaults: handle.defaults)
        original.selection = .travel
        let restored = FeatureHub(defaults: handle.defaults)
        let model = AppModel(defaults: handle.defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = language
        model.jump(to: Date(timeIntervalSince1970: 1_788_998_400), animated: false)
        let root = FeatureWorkspaceView(hub: restored)
            .environment(model).environment(model.core)
            .environment(\.featureHub, restored).environment(\.locale, model.uiLocale)
            .environment(\.textScale, model.settings.textSize.scale).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
            restored.setVisible(false)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dayside-navigation-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("restored-\(model.uiLocale.identifier).png")
        try png.write(to: output)
        print("NAVIGATION_RENDER\t\(model.uiLocale.identifier)\t\(restored.selection.rawValue)\t\(output.path)")
        #expect(restored.selection == .travel)
    }
}
