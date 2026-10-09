// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation
import ObjectiveC
import Testing
@testable import Dayside

@Suite(.serialized)
@MainActor
struct QuietActivationPolicyTests {
    @Test
    func repeatedPolicyRequestsKeepTheQuietHostAccessory() throws {
        try #require(ApplicationSession.isTesting && TestHostWindowPolicy.isQuiet)
        try #require(TestHostWindowPolicy.activationGuardsAreInstalled)
        #expect(NSApp.activationPolicy() == .accessory)
        for requested in [NSApplication.ActivationPolicy.accessory, .regular, .prohibited, .accessory] {
            #expect(NSApp.setActivationPolicy(requested))
            #expect(NSApp.activationPolicy() == .accessory)
            #expect(!NSApp.isActive)
        }
        TestHostWindowPolicy.installIfNeeded()
        TestHostWindowPolicy.installIfNeeded()
        #expect(NSApp.activationPolicy() == .accessory)
        #expect(NSApp.setActivationPolicy(.regular))
        #expect(NSApp.activationPolicy() == .accessory)
    }

    @Test
    func runningApplicationActivationRequestsStayInactiveAndNonfrontmost() async throws {
        try #require(ApplicationSession.isTesting && TestHostWindowPolicy.isQuiet)
        try #require(TestHostWindowPolicy.activationGuardsAreInstalled)
        let ownerFrontmost = try #require(NSWorkspace.shared.frontmostApplication)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        try #require(ownerFrontmost.processIdentifier != ownPID)
        let host = NSRunningApplication.current
        #expect(!host.activate(options: []))
        #expect(!host.activate(from: ownerFrontmost, options: []))
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(300))
        let actualFrontmost = try #require(NSWorkspace.shared.frontmostApplication)
        #expect(actualFrontmost.processIdentifier != ownPID)
        #expect(!host.isActive)
        #expect(!NSApp.isActive)
        #expect(NSApp.activationPolicy() == .accessory)
    }

    @Test
    func alreadyAccessoryAvoidsCallingThePolicySetter() {
        var calls = 0
        let accepted = TestHostWindowPolicy.requestAccessoryPolicy(current: { .accessory }, set: {
            calls += 1
            return false
        })
        #expect(accepted)
        #expect(calls == 0)
    }

    @Test
    func aFalseSetterResultAcceptsTheActualAccessoryPolicy() {
        var actual = NSApplication.ActivationPolicy.regular
        var calls = 0
        let accepted = TestHostWindowPolicy.requestAccessoryPolicy(current: { actual }, set: {
            calls += 1
            actual = .accessory
            return false
        })
        #expect(accepted)
        #expect(actual == .accessory)
        #expect(calls == 1)
    }

    @Test
    func aRefusedPolicyChangeReturnsFalseWithoutCrashing() {
        var calls = 0
        let accepted = TestHostWindowPolicy.requestAccessoryPolicy(current: { .regular }, set: {
            calls += 1
            return false
        })
        #expect(!accepted)
        #expect(calls == 1)
    }

    @Test
    func aTrueSetterResultCannotHideAnUnchangedPolicy() {
        let accepted = TestHostWindowPolicy.requestAccessoryPolicy(current: { .regular }, set: { true })
        #expect(!accepted)
    }

    @Test
    func aSuccessfulPolicyChangeIsAccepted() {
        var actual = NSApplication.ActivationPolicy.regular
        var calls = 0
        let accepted = TestHostWindowPolicy.requestAccessoryPolicy(current: { actual }, set: {
            calls += 1
            actual = .accessory
            return true
        })
        #expect(accepted)
        #expect(actual == .accessory)
        #expect(calls == 1)
    }

    @Test
    func bundleLoadingRepairsAReplacedActivationGuardWithoutActivating() throws {
        try #require(ApplicationSession.isTesting && TestHostWindowPolicy.isQuiet)
        try #require(TestHostWindowPolicy.activationGuardsAreInstalled)
        let method = try #require(class_getInstanceMethod(NSApplication.self, NSSelectorFromString("activate")))
        let previous = method_getImplementation(method)
        let noActivation: @convention(block) (NSApplication) -> Void = { _ in }
        let replacement = imp_implementationWithBlock(noActivation)
        defer {
            method_setImplementation(method, previous)
            TestHostWindowPolicy.installIfNeeded()
            imp_removeBlock(replacement)
        }
        method_setImplementation(method, replacement)
        #expect(!TestHostWindowPolicy.activationGuardsAreInstalled)
        NotificationCenter.default.post(name: Bundle.didLoadNotification, object: nil)
        #expect(TestHostWindowPolicy.activationGuardsAreInstalled)
        #expect(!NSApp.isActive)
        let frontmost = try #require(NSWorkspace.shared.frontmostApplication)
        #expect(frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier)
    }
}
