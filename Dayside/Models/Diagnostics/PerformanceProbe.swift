// SPDX-License-Identifier: GPL-3.0-only
#if DEBUG
import AppKit
import CoreSpotlight
import CryptoKit
import Darwin
import Foundation

/// 同一个测试宿主协议，逐次启动只量一个场景。
@MainActor
enum PerformanceProbe {
    struct Configuration: Equatable {
        let scenario: String
        let page: FeatureSelection?
        nonisolated init?(environment: [String: String], testHost: Bool) {
            guard testHost, let scenario = environment["MEANTIME_PERF_SCENARIO"] else { return nil }
            let prefix = scenario.hasPrefix("cold:") ? "cold:" : "cold-"
            if scenario.hasPrefix(prefix), let page = FeatureSelection(rawValue: String(scenario.dropFirst(prefix.count))) {
                self.scenario = scenario
                self.page = page
            } else if ["idle", "panel", "tools-tour", "earth", "converter", "spotlight", "add-place", "understand", "surfaces"].contains(scenario) {
                self.scenario = scenario
                page = nil
            } else { return nil }
        }
    }
    static let configuration = Configuration(environment: ProcessInfo.processInfo.environment,
                                             testHost: ApplicationSession.isTesting)
    static var isRequested: Bool { configuration != nil }
    private static var started = false
    static let fixedInstant = Date(timeIntervalSince1970: 1_791_115_200)
    static let idleSeconds = 60
    static let earthSeconds = 30
    static let converterText = "2026-10-04 09:00"
    #if DAYSIDE_PERF_LEGACY
    static let mapRenderer = "legacy-scene"
    #else
    static let mapRenderer = "iosurface"
    #endif
    private static var conversionPlaces = 0
    static func recordConversion(places: Int) {
        guard configuration?.scenario == "converter" else { return }
        conversionPlaces = places
    }

    static func seed(_ defaults: UserDefaults) {
        var zones: [TimeZoneEntry] = [
            .init(timezoneID: "America/Los_Angeles", cityName: "Los Angeles", coordinate: .init(latitude: 34.05, longitude: -118.24), countryCode: "US"),
            .init(timezoneID: "Europe/London", cityName: "London", coordinate: .init(latitude: 51.51, longitude: -0.13), countryCode: "GB"),
            .init(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: .init(latitude: 35.68, longitude: 139.69), countryCode: "JP"),
            .init(timezoneID: "Australia/Perth", cityName: "Perth", coordinate: .init(latitude: -31.95, longitude: 115.86), countryCode: "AU"),
            .init(timezoneID: "Pacific/Auckland", cityName: "Auckland", coordinate: .init(latitude: -36.85, longitude: 174.76), countryCode: "NZ")
        ]
        for index in zones.indices {
            zones[index].id = UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", index + 1))!
        }
        Store.saveZones(zones, to: defaults)
        var settings = Store.loadSettings(from: defaults)
        settings.hourStyle = .force24
        settings.planner.isExpanded = true
        settings.planner.excludedZoneIDs = zones.dropFirst(2).map(\.id)
        Store.saveSettings(settings, to: defaults)
        struct People: Encodable { let version = 1; let people: [PersonProfile] }
        var people = [PersonProfile(name: "Ana", timeZoneID: "Europe/London", countryCode: "GB"),
                      PersonProfile(name: "Mei", timeZoneID: "Asia/Tokyo", countryCode: "JP"),
                      PersonProfile(name: "Nia", timeZoneID: "Pacific/Auckland", countryCode: "NZ")]
        for index in people.indices {
            people[index].id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
        }
        defaults.set(try? JSONEncoder().encode(People(people: people)), forKey: PeopleStore.storageKey)
    }

    static func fixtureHash(_ defaults: UserDefaults) -> String {
        let zones = Store.loadZones(from: defaults).zones.map { zone -> [String: Any] in
            ["id": zone.id.uuidString, "zone": zone.timezoneID, "name": zone.cityName,
             "latitude": zone.coordinate?.latitude ?? 0, "longitude": zone.coordinate?.longitude ?? 0,
             "country": zone.countryCode ?? ""]
        }
        let people = PeopleStore(defaults: defaults).people.map { person -> [String: Any] in
            ["id": person.id.uuidString, "name": person.name, "zone": person.timeZoneID, "country": person.countryCode ?? "",
             "start": person.schedule.startMinute, "end": person.schedule.endMinute, "weekdays": person.schedule.workingWeekdays]
        }
        let settings = Store.loadSettings(from: defaults)
        let value: [String: Any] = ["version": 1, "zones": zones, "people": people,
            "hourStyle": settings.hourStyle.rawValue, "interfaceLanguage": settings.interfaceLanguage.rawValue,
            "plannerExpanded": settings.planner.isExpanded, "plannerExcluded": settings.planner.excludedZoneIDs.map(\.uuidString).sorted(),
            "appearance": ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_APPEARANCE"] ?? "system",
            "timePolicy": configuration?.scenario == "surfaces" ? "live-launch-idle-fixed-view-and-closed" : "fixed-view-live-idle",
            "viewInstant": fixedInstant.timeIntervalSince1970, "conversionSourceTime": converterText]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func runIfRequested(model: AppModel, hub: FeatureHub, open: @escaping (String) -> Void, settings: @escaping () -> Void = {}) {
        guard let configuration, !started else { return }
        started = true
        Task { @MainActor in
            let scenario = configuration.scenario
            let personCount = PeopleStore(defaults: ApplicationSession.defaults).people.count
            emit("ready", scenario: scenario, extra: ["protocol": 1, "surfaceProtocol": 2, "mapRenderer": mapRenderer,
                  "places": model.zones.count, "people": personCount,
                  "reduceMotion": false, "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  "realClockUnix": model.now.timeIntervalSince1970, "viewInstantUnix": fixedInstant.timeIntervalSince1970,
                  "fixture": "store", "fixtureHash": fixtureHash(ApplicationSession.defaults), "suite": "disposable", "pages": FeatureSelection.allCases.filter(hub.isAvailable).map(\.rawValue)])
            do {
                guard model.zones.count == 5, personCount == 3 else { throw ProbeError.failed("fixture count mismatch") }
                try await pause(2)
                if scenario == "surfaces" {
                    try await surfaceTour(model: model, hub: hub, open: open, settings: settings)
                    emit("complete", scenario: scenario)
                    return
                }
                #if DAYSIDE_PERF_LEGACY
                if scenario == "understand" {
                    emit("unavailable", scenario: scenario, extra: ["reason": "engine absent in baseline", "capability": "engineAbsent"])
                    try await diagnosticsHold(scenario)
                    emit("complete", scenario: scenario)
                    return
                }
                #endif
                if configuration.page != nil || ["tools-tour", "earth", "converter"].contains(scenario) {
                    model.jump(to: fixedInstant, animated: false)
                }
                emit("begin", scenario: scenario, phase: "active")
                if let page = configuration.page {
                    try await show(page, hub: hub, open: open, scenario: scenario)
                    try await pause(5)
                    try await diagnosticsHold(scenario)
                    emit("end", scenario: scenario, phase: "active")
                    try await pause(2)
                    try await closeAndVerify("tools", model: model, hub: hub)
                } else {
                    switch scenario {
                    case "idle":
                        try await pause(idleSeconds)
                        emit("end", scenario: scenario, phase: "active")
                    case "panel":
                        guard MenuBarPanel.toggle() == .clicked else { throw ProbeError.failed("panel unavailable") }
                        try await pause(1)
                        guard try await waitForReadiness({ model.isPanelVisible && panelIsVisibleAndKey() }) else {
                            throw ProbeError.failed("panel did not become visible and key within readiness deadline")
                        }
                        emit("checkpoint", scenario: scenario, extra: ["visible": true, "front": NSApp.keyWindow?.isVisible == true, "window": "panel", "windowInventory": MenuBarPanel.windowInventory()])
                        let anchor = fixedInstant
                        for step in 0...120 {
                            model.jump(to: anchor.addingTimeInterval((-12 + 24 * Double(step) / 120) * 3600), animated: false)
                            try await Task.sleep(for: .milliseconds(33))
                        }
                        let framesBeforeJumps = PerformanceRustCalls.animationFrames
                        var jumpFrames: [Int] = []
                        for hours in [Double](arrayLiteral: 3, 6, 9, 12, -6, -12) {
                            guard model.isPanelVisible, panelIsVisibleAndKey() else {
                                throw ProbeError.failed("panel lost visibility or key status before jump at \(hours)h")
                            }
                            let before = PerformanceRustCalls.animationFrames
                            model.jump(to: anchor.addingTimeInterval(hours * 3600), animated: true)
                            try await pause(1)
                            let frames = PerformanceRustCalls.animationFrames - before
                            guard frames > 1 else { throw ProbeError.failed("jump at \(hours)h produced no intermediate frames") }
                            jumpFrames.append(frames)
                        }
                        let animatedFrames = PerformanceRustCalls.animationFrames - framesBeforeJumps
                        guard animatedFrames > 6 else { throw ProbeError.failed("six jumps produced no intermediate animation frames") }
                        emit("checkpoint", scenario: scenario, extra: ["animatedFrames": animatedFrames, "jumpFrames": jumpFrames, "jumps": 6, "scrubHours": [-12, 12], "visible": model.isPanelVisible, "front": NSApp.keyWindow?.isVisible == true])
                        try await diagnosticsHold(scenario)
                        model.resetToNow()
                        guard MenuBarPanel.toggle() == .clicked else { throw ProbeError.failed("panel close unavailable") }
                        try await pause(1)
                        guard !model.isPanelVisible else { throw ProbeError.failed("panel remained visible") }
                        emit("end", scenario: scenario, phase: "active")
                        try await idleAfterClose(scenario)
                    case "tools-tour":
                        for page in FeatureSelection.allCases where hub.isAvailable(page) {
                            try await show(page, hub: hub, open: open, scenario: scenario)
                            try await pause(2)
                        }
                        try await diagnosticsHold(scenario)
                        try await closeAndVerify("tools", model: model, hub: hub)
                        emit("end", scenario: scenario, phase: "active")
                        try await idleAfterClose(scenario)
                    case "earth":
                        open("earth")
                        try await front("earth", scenario: scenario)
                        guard let earth = window("earth") else { throw ProbeError.failed("Earth absent after foreground") }
                        let witness = PerformanceForegroundWitness()
                        let center = NotificationCenter.default
                        let keyObserver = center.addObserver(forName: NSWindow.didResignKeyNotification, object: earth, queue: nil) { _ in witness.markLost() }
                        let appObserver = center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: nil) { _ in witness.markLost() }
                        defer { center.removeObserver(keyObserver); center.removeObserver(appObserver) }
                        try await pause(earthSeconds)
                        guard !witness.wasLost, earth.isVisible, earth.isKeyWindow,
                              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
                            throw ProbeError.failed("Earth lost foreground during interval")
                        }
                        center.removeObserver(keyObserver)
                        center.removeObserver(appObserver)
                        emit("checkpoint", scenario: scenario, extra: ["earthForegroundSeconds": earthSeconds, "foregroundInterrupted": false, "visible": true, "front": true])
                        #if DAYSIDE_PERF_LEGACY
                        let places = WorldMapView.places(in: model.core)
                        let labels = places.zones.map { WorldMapView.label(for: $0, model: model, core: model.core) }
                        guard let poster = EarthPoster.image(instant: model.referenceDate, places: places.places, labels: labels,
                                                          caption: "Dayside performance fixture", locale: model.uiLocale),
                              let png = TimeCardImage.pngData(poster), let tiff = poster.tiffRepresentation else {
                            throw ProbeError.failed("poster render failed")
                        }
                        // 私有剪贴板走同样的 PNG/TIFF 拷贝，不读写用户剪贴板。
                        let board = NSPasteboard.withUniqueName()
                        board.setData(png, forType: .png)
                        board.setData(tiff, forType: .tiff)
                        #else
                        let board = NSPasteboard.withUniqueName()
                        guard EarthPoster.copy(model: model, core: model.core, pasteboard: board),
                              let png = board.data(forType: .png), let tiff = board.data(forType: .tiff) else {
                            board.releaseGlobally()
                            throw ProbeError.failed("poster copy failed")
                        }
                        #endif
                        emit("checkpoint", scenario: scenario, extra: ["posterPNG": png.count, "posterTIFF": tiff.count,
                              "pasteboard": "private", "visible": earth.isVisible, "front": earth.isKeyWindow])
                        board.releaseGlobally()
                        try await diagnosticsHold(scenario)
                        try await closeAndVerify("earth", model: model, hub: hub)
                        emit("end", scenario: scenario, phase: "active")
                        try await idleAfterClose(scenario)
                    case "converter":
                        // 空白初态让两版都走既有测试夹具的填字与换算路径。
                        hub.conversionText = ""
                        hub.conversionSourceID = model.zones.first?.id.uuidString
                        try await show(.convert, hub: hub, open: open, scenario: scenario)
                        try await pause(5)
                        guard conversionPlaces == 5 else { throw ProbeError.failed("converter did not render five-place reading: \(conversionPlaces)") }
                        emit("checkpoint", scenario: scenario, extra: ["readingPlaces": conversionPlaces, "reading": converterText])
                        try await diagnosticsHold(scenario)
                        emit("end", scenario: scenario, phase: "active")
                        try await pause(2)
                        try await closeAndVerify("tools", model: model, hub: hub)
                    case "spotlight":
                        let backend = PerformanceSpotlightBackend()
                        let operationStarted = DispatchTime.now().uptimeNanoseconds
                        let result = await SpotlightPlaceIndex.rebuildIfNeeded(seed: SpotlightPlaceIndex.seed(model: model), backend: backend)
                        let operationNanoseconds = DispatchTime.now().uptimeNanoseconds - operationStarted
                        guard case let .rebuilt(count, _) = result else {
                            try? await backend.remove()
                            throw ProbeError.failed("Spotlight failed: \(result)")
                        }
                        emit("checkpoint", scenario: scenario, extra: ["indexedPlaces": count, "index": backend.name, "backend": "CoreSpotlight", "operation_ns": operationNanoseconds, "observationTailSeconds": 2])
                        try await pause(2)
                        emit("end", scenario: scenario, phase: "active", extra: ["operation_ns": operationNanoseconds, "observationTailSeconds": 2])
                        try await backend.remove()
                    case "add-place":
                        guard hub.handle(.init(action: "addPlace", arguments: ["timeZoneID": "America/New_York", "name": "New York"])) else {
                            throw ProbeError.failed("add place failed")
                        }
                        guard model.zones.count == 6 else { throw ProbeError.failed("added place absent") }
                        try await pause(2)
                        emit("end", scenario: scenario, phase: "active", extra: ["places": model.zones.count])
                    case "understand":
                        #if DAYSIDE_PERF_LEGACY
                        emit("end", scenario: scenario, phase: "active", extra: ["available": false, "reason": "engine absent in baseline", "capability": "engineAbsent"])
                        #else
                        let output = TimeUnderstanding.read("9:00", region: "US", language: "en")
                        guard !output.failed, !output.mentions.isEmpty else { throw ProbeError.failed("first understand call failed") }
                        emit("checkpoint", scenario: scenario, extra: ["mentions": output.mentions.count, "input": "9:00", "cityIndexNeeded": false])
                        try await pause(2)
                        emit("end", scenario: scenario, phase: "active", extra: ["available": true])
                        #endif
                    default: throw ProbeError.failed("unknown scenario")
                    }
                }
                if ["idle", "spotlight", "add-place", "understand"].contains(scenario) {
                    try await diagnosticsHold(scenario)
                }
                emit("complete", scenario: scenario)
            } catch {
                let key = NSApp.keyWindow
                let front = NSWorkspace.shared.frontmostApplication
                emit("error", scenario: scenario, extra: ["message": String(describing: error),
                    "keyWindow": key?.identifier?.rawValue ?? "", "keyWindowType": key.map { String(describing: type(of: $0)) } ?? "",
                    "keyWindowVisible": key?.isVisible ?? false, "appActive": NSApp.isActive,
                    "frontPID": front?.processIdentifier ?? -1, "frontBundleID": front?.bundleIdentifier ?? "",
                    "windowInventory": MenuBarPanel.windowInventory()])
            }
        }
    }

    // 按真实窗口顺序量，每一页保留开页前、停稳与峰值边界。
    private static func surfaceTour(model: AppModel, hub: FeatureHub, open: (String) -> Void, settings: () -> Void) async throws {
        let scenario = "surfaces"
        func begin(_ phase: String) { emit("begin", scenario: scenario, phase: phase) }
        func end(_ phase: String) async throws {
            if ["panel", "earth-open", "earth-scrub"].contains(phase) {
                try witnessMap(phase: phase, scenario: scenario)
            }
            emit("end", scenario: scenario, phase: phase)
            if ProcessInfo.processInfo.environment["MEANTIME_PERF_SURFACE_DIAGNOSTICS"] == "1" {
                emit("checkpoint", scenario: scenario, extra: ["surfaceDiagnostics": phase])
                try await pause(10)
            }
        }
        func visible(_ prefix: String) async throws {
            guard try await waitForReadiness({ window(prefix) != nil }) else {
                throw ProbeError.failed("surface not visible: \(prefix)")
            }
            emit("checkpoint", scenario: scenario, extra: ["window": prefix, "visible": true])
        }
        begin("idle")
        try await pause(idleSeconds)
        try await end("idle")
        model.jump(to: fixedInstant, animated: false)
        begin("panel")
        guard MenuBarPanel.toggle() == .clicked else { throw ProbeError.failed("panel open unavailable") }
        guard try await waitForReadiness({ model.isPanelVisible }) else { throw ProbeError.failed("panel invisible") }
        try await pause(5)
        try await end("panel")
        begin("panel-closed")
        guard MenuBarPanel.toggle() == .clicked else { throw ProbeError.failed("panel close unavailable") }
        try await pause(2)
        guard !model.isPanelVisible else { throw ProbeError.failed("panel remained visible") }
        guard !hub.isVisible else { throw ProbeError.failed("tools opened before the closed-panel baseline") }
        emit("checkpoint", scenario: scenario, extra: ["closedPanelBaseline": true,
                                                       "panelVisible": model.isPanelVisible, "toolsVisible": hub.isVisible])
        try await end("panel-closed")
        for page in FeatureSelection.allCases where hub.isAvailable(page) {
            let phase = "page-" + page.rawValue
            begin(phase)
            hub.selection = page
            open("tools")
            try await visible("tools")
            guard hub.selection == page else { throw ProbeError.failed("page selection mismatch") }
            emit("checkpoint", scenario: scenario, extra: ["page": page.rawValue])
            try await pause(5)
            try await end(phase)
        }
        try await closeAndVerify("tools", model: model, hub: hub)
        begin("settings")
        settings()
        try await visible("com_apple_SwiftUI_Settings")
        try await pause(5)
        try await end("settings")
        try await closeAndVerify("com_apple_SwiftUI_Settings", model: model, hub: hub)
        begin("welcome")
        open("welcome")
        try await visible("welcome")
        try await pause(5)
        try await end("welcome")
        try await closeAndVerify("welcome", model: model, hub: hub)
        model.jump(to: fixedInstant, animated: false)
        begin("earth-open")
        open("earth")
        try await visible("earth")
        try await pause(5)
        try await end("earth-open")
        begin("earth-scrub")
        model.jump(to: fixedInstant.addingTimeInterval(3 * 3600), animated: false)
        try await pause(5)
        try await end("earth-scrub")
        begin("earth-closed")
        try await closeAndVerify("earth", model: model, hub: hub)
        try await pause(1)
        try await end("earth-closed")
        begin("closed")
        try await pause(2)
        guard !model.isPanelVisible, !hub.isVisible,
              !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) else {
            throw ProbeError.failed("surface remained visible")
        }
        try await end("closed")
        begin("closed-idle")
        try await pause(idleSeconds)
        try await end("closed-idle")
    }

    private static func diagnosticsHold(_ scenario: String) async throws {
        guard ProcessInfo.processInfo.environment["MEANTIME_PERF_DIAGNOSTICS"] == "1" else { return }
        emit("checkpoint", scenario: scenario, extra: ["diagnosticsReady": true])
        try await pause(20)
    }

    private enum ProbeError: Error { case failed(String) }
    private static func pause(_ seconds: Int) async throws { try await Task.sleep(for: .seconds(seconds)) }
    private static func idleAfterClose(_ scenario: String) async throws {
        try await pause(2)
        emit("begin", scenario: scenario, phase: "post-close")
        try await pause(idleSeconds)
        emit("end", scenario: scenario, phase: "post-close")
    }
    private static func window(_ prefix: String) -> NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix(prefix) && $0.isVisible }
    }

    private static func witnessMap(phase: String, scenario: String) throws {
        let target = phase == "panel" ? NSApp.windows.first {
            String(describing: type(of: $0)).contains("MenuBarExtraWindow") && $0.isVisible
        } : window("earth")
        guard let target, target.occlusionState.contains(.visible) else {
            throw ProbeError.failed("map window occluded: \(phase)")
        }
        var details: [String: Any] = ["visible": target.isVisible, "occlusionVisible": true, "mapRenderer": mapRenderer]
        #if !DAYSIDE_PERF_LEGACY
        var pending = target.contentView.map { [$0] } ?? []
        var maps = 0, surfaces = 0
        while let view = pending.popLast() {
            guard !view.isHiddenOrHasHiddenAncestor else { continue }
            if let map = view as? MapSurfaceView, map.layer?.contents != nil {
                maps += 1
                surfaces += map.ownedSurfaceCount
            }
            pending.append(contentsOf: view.subviews)
        }
        guard maps > 0, surfaces > 0 else { throw ProbeError.failed("map backing absent: \(phase)") }
        details["mapViews"] = maps
        details["mapSurfaces"] = surfaces
        #endif
        emit("checkpoint", scenario: scenario, phase: phase, extra: details)
    }
    private static func panelIsVisibleAndKey() -> Bool {
        NSApp.windows.contains { String(describing: type(of: $0)).contains("MenuBarExtraWindow") && $0.isVisible && $0.isKeyWindow }
    }

    private static func waitForReadiness(_ ready: () -> Bool) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var consecutive = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            consecutive = ready() ? consecutive + 1 : 0
            if consecutive == 2 { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func front(_ prefix: String, scenario: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard let window = window(prefix) else { throw ProbeError.failed("window absent: \(prefix)") }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard try await waitForReadiness({
            window.isVisible && window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        }) else { throw ProbeError.failed("window not foreground within readiness deadline: \(prefix)") }
        emit("checkpoint", scenario: scenario, extra: ["window": prefix, "visible": true, "front": true])
    }
    private static func show(_ page: FeatureSelection, hub: FeatureHub, open: (String) -> Void, scenario: String) async throws {
        hub.selection = page
        open("tools")
        try await front("tools", scenario: scenario)
        guard hub.selection == page else { throw ProbeError.failed("restored page differs from requested page: \(hub.selection.rawValue)") }
        emit("checkpoint", scenario: scenario, extra: ["page": hub.selection.rawValue])
    }
    private static func closeAndVerify(_ prefix: String, model: AppModel, hub: FeatureHub) async throws {
        NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix(prefix) && $0.isVisible }.forEach { $0.performClose(nil) }
        try await Task.sleep(for: .milliseconds(400))
        let stateVisible = prefix == "tools" && hub.isVisible
        guard window(prefix) == nil, !stateVisible else { throw ProbeError.failed("window remained visible after close: \(prefix)") }
    }
    private static func emit(_ event: String, scenario: String, phase: String? = nil, extra: [String: Any] = [:]) {
        var value = extra
        value["event"] = event
        value["scenario"] = scenario
        value["phase"] = phase
        value["uptime_ns"] = DispatchTime.now().uptimeNanoseconds
        value["animated_frames"] = PerformanceRustCalls.animationFrames
        if value["animatedFrames"] == nil { value["animatedFrames"] = PerformanceRustCalls.animationFrames }
        value["meter"] = PerformanceMeter.line()
        value["rustCalls"] = PerformanceRustCalls.snapshot()
        value["rustWall_ns"] = PerformanceRustCalls.durations()
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data("MEANTIME_PERF \(json)\n".utf8))
    }
}

nonisolated private final class PerformanceForegroundWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var lost = false
    func markLost() { lock.lock(); lost = true; lock.unlock() }
    var wasLost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }
}

private struct PerformanceSpotlightBackend: SpotlightIndexBackend {
    let name = "com.dayside.performance.\(UUID().uuidString)"
    var isAvailable: Bool { CSSearchableIndex.isIndexingAvailable() }
    func lastVersion() async throws -> String? { nil }
    func replaceAll(_ items: [CSSearchableItem], version: String, hadPrevious: Bool) async throws {
        let index = CSSearchableIndex(name: name)
        // 先等条目写入，再提交版本；批内等条目回调会阻塞提交。
        try await index.indexSearchableItems(items)
        index.beginBatch()
        try await index.endBatch(withClientState: Data(version.utf8))
    }
    func remove() async throws { try await CSSearchableIndex(name: name).deleteAllSearchableItems() }
}

/// 量尺独立于应用版本，累计值由外面按 begin/end 相减。
nonisolated enum PerformanceMeter {
    static func line() -> String {
        var usage = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
        } == 0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ns = { (ticks: UInt64) in timebase.denom == 0 ? ticks : ticks / UInt64(timebase.denom) * UInt64(timebase.numer) }
        var power = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let powerOK = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        } == KERN_SUCCESS
        var fields: [String] = []
        if ok {
            fields = ["fp=\(usage.ri_phys_footprint)", "peak=\(usage.ri_lifetime_max_phys_footprint)", "rss=\(usage.ri_resident_size)",
                      "cpu_ns=\(ns(usage.ri_user_time + usage.ri_system_time))", "energy_nj=\(usage.ri_energy_nj)",
                      "wake=\(usage.ri_interrupt_wkups)", "idlewake=\(usage.ri_pkg_idle_wkups)"]
        }
        if powerOK { fields.append("gpu=\(power.gpu_energy.task_gpu_utilisation)") }
        return fields.joined(separator: " ")
    }
}

/// 调用计数只在显式归因运行启用，常规测量没有逐调用锁开销。
nonisolated enum PerformanceRustCalls {
    static let enabled = ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1"
        && ProcessInfo.processInfo.environment["MEANTIME_PERF_SCENARIO"] != nil
        && ProcessInfo.processInfo.environment["MEANTIME_PERF_COUNTS"] == "1"
    private static let storage = Storage()
    static let animationEnabled = ProcessInfo.processInfo.environment["MEANTIME_TEST_HOST"] == "1"
        && ProcessInfo.processInfo.environment["MEANTIME_PERF_SCENARIO"] != nil
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
        var frames: [String: Int] = [:]
        var animationFrames = 0
        var durations: [String: UInt64] = [:]
    }
    static var animationFrames: Int {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.animationFrames
    }
    static func animationFrame() {
        guard animationEnabled else { return }
        storage.lock.lock()
        storage.animationFrames += 1
        storage.lock.unlock()
    }
    static func begin() -> UInt64? { enabled ? DispatchTime.now().uptimeNanoseconds : nil }
    static func end(_ operation: String, started: UInt64?) {
        guard let started else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        storage.lock.lock()
        storage.counts[operation, default: 0] += 1
        storage.durations[operation, default: 0] += elapsed
        storage.lock.unlock()
    }
    static func durations() -> [String: UInt64] {
        guard enabled else { return [:] }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.durations
    }
    static func record(_ operation: String) {
        guard enabled else { return }
        storage.lock.lock()
        storage.counts[operation, default: 0] += 1
        storage.lock.unlock()
    }
    static func frame(_ surface: String) {
        guard enabled else { return }
        storage.lock.lock()
        storage.frames[surface, default: 0] += 1
        storage.lock.unlock()
    }
    static func snapshot() -> [String: Int] {
        guard enabled else { return [:] }
        storage.lock.lock()
        defer { storage.lock.unlock() }
        var result = storage.counts
        for (surface, count) in storage.frames { result["frames.\(surface)"] = count }
        return result
    }
}
#endif
