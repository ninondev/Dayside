// SPDX-License-Identifier: GPL-3.0-only
//
//  MapScrubTests.swift
//  地图手势：拖地图 / 横扫触控板换算成时间、松手对齐整刻钟、地球窗标签不互相压住。
//  判据用另一套算法：太阳直射点经度随时间的变化（Rust `worldmap.scene` 给的 subsolar）与手势换算的分钟对上。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dayside

@MainActor
private final class EarthFullscreenTransition {
    var entryRequested = false
    var entered = false
    var exited = false
    var exitRequested = false
}

@Suite(.serialized)
struct MapScrubTests {
    @Test func draggingTheFullWidthMovesTimeBy24HoursAndTheSunFollowsThePointer() {
        #expect(MapScrub.minutes(forDrag: 288, width: 288) == -1440)
        #expect(MapScrub.minutes(forDrag: -144, width: 288) == 720)
        #expect(MapScrub.minutes(forDrag: 12, width: 288) == -60)
        #expect(MapScrub.minutes(forDrag: 10, width: 0) == 0)
        #expect(MapScrub.minutes(forDrag: .nan, width: 288) == 0)
        // 独立判据：拖 dx 后太阳直射点在图上的横坐标应当也挪了 dx（太阳跟着指针走）。
        let width = 288.0, start = Date(timeIntervalSince1970: 1_789_542_000)
        for dx in [-100.0, -12, 7, 60, 143] {
            let later = start.addingTimeInterval(MapScrub.minutes(forDrag: dx, width: width) * 60)
            let a = WorldMapScene.scene(instant: start, size: CGSize(width: width, height: width / 2), places: [])
            let b = WorldMapScene.scene(instant: later, size: CGSize(width: width, height: width / 2), places: [])
            var moved = b.sun[0] - a.sun[0]
            if moved > width / 2 { moved -= width } else if moved < -width / 2 { moved += width }
            #expect(abs(moved - dx) < 0.5, "拖 \(dx) pt 太阳挪了 \(moved) pt")
        }
    }

    @Test func trackpadSwipesFollowTheFingersWhateverTheScrollDirectionSetting() {
        #expect(MapScrub.fingerDX(scrollingDeltaX: 5, invertedFromDevice: true) == 5)
        #expect(MapScrub.fingerDX(scrollingDeltaX: 5, invertedFromDevice: false) == -5)
    }

    @Test func releasingSnapsToAQuarterHourEverywhereIncludingKathmanduAndChatham() {
        let base = Date(timeIntervalSince1970: 1_789_542_000)   // 整刻钟
        #expect(MapScrub.snapped(base.addingTimeInterval(7 * 60)) == base)
        #expect(MapScrub.snapped(base.addingTimeInterval(8 * 60)) == base.addingTimeInterval(15 * 60))
        for id in ["Asia/Kathmandu", "Pacific/Chatham", "Australia/Eucla", "Asia/Kolkata", "America/St_Johns", "Australia/Lord_Howe"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: id)!
            for k in 0..<40 {
                let snapped = MapScrub.snapped(base.addingTimeInterval(Double(k) * 437))
                let minute = calendar.component(.minute, from: snapped)
                #expect(minute % 15 == 0, "\(id) 对齐后是 :\(minute)")
            }
        }
        #expect(MapScrub.wholeMinute(base.addingTimeInterval(29)) == base)
        #expect(MapScrub.wholeMinute(base.addingTimeInterval(31)) == base.addingTimeInterval(60))
    }

    @Test func earthLabelsStayInsideTheMapAndDoNotOverlapWhenThereIsRoom() {
        let bounds = CGSize(width: 900, height: 450)
        // 成都、重庆、香港、台北、东京挨得很近；加上贴边的檀香山与奥克兰。
        let points: [(index: Int, point: CGPoint)] = [(0, CGPoint(x: 700, y: 170)), (1, CGPoint(x: 705, y: 172)), (2, CGPoint(x: 735, y: 190)),
                                                     (3, CGPoint(x: 750, y: 180)), (4, CGPoint(x: 800, y: 140)), (5, CGPoint(x: 3, y: 200)),
                                                     (6, CGPoint(x: 897, y: 330))]
        let sizes = Dictionary(uniqueKeysWithValues: points.map { ($0.index, CGSize(width: 96, height: 18)) })
        let placed = MapLabelLayout.place(points: points, sizes: sizes, in: bounds)
        #expect(placed.map(\.index) == Array(0..<7))
        for label in placed {
            let r = CGRect(x: label.center.x - label.size.width / 2, y: label.center.y - label.size.height / 2, width: label.size.width, height: label.size.height)
            #expect(r.minX >= 0 && r.maxX <= bounds.width && r.minY >= 0 && r.maxY <= bounds.height, "标签 \(label.index) 出界：\(r)")
        }
        var overlaps = 0
        for i in placed.indices { for j in placed.indices where j > i {
            let a = placed[i], b = placed[j]
            let ra = CGRect(x: a.center.x - a.size.width / 2, y: a.center.y - a.size.height / 2, width: a.size.width, height: a.size.height)
            let rb = CGRect(x: b.center.x - b.size.width / 2, y: b.center.y - b.size.height / 2, width: b.size.width, height: b.size.height)
            if ra.intersects(rb) { overlaps += 1 }
        } }
        #expect(overlaps == 0)
    }

    /// 键盘 ← → 与读屏「调整」的一步：走到钟面上下一个 / 上一个整点或整刻钟。判据：`Calendar` 在该时区读出的分钟
    /// （另一套算法）必须对齐、时刻严格往前（往后）走、一步不超过步长加一小时（换钟那一步）。
    @Test func arrowKeysStepToTheNextWholeHourOrQuarterOnTheLocalClockFace() {
        func date(_ s: String, _ id: String) -> Date {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: id)
            f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
        }
        func wall(_ d: Date, _ id: String) -> String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: id)
            f.dateFormat = "HH:mm zzz"; return f.string(from: d)
        }
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(wall(MapScrub.step(from: date("2026-09-24 04:57", la.identifier), minutes: 60, forward: true, in: la), la.identifier) == "05:00 PDT")
        #expect(wall(MapScrub.step(from: date("2026-09-24 05:00", la.identifier), minutes: 60, forward: true, in: la), la.identifier) == "06:00 PDT")
        #expect(wall(MapScrub.step(from: date("2026-09-24 04:57", la.identifier), minutes: 60, forward: false, in: la), la.identifier) == "04:00 PDT")
        #expect(wall(MapScrub.step(from: date("2026-09-24 04:00", la.identifier), minutes: 60, forward: false, in: la), la.identifier) == "03:00 PDT")
        #expect(wall(MapScrub.step(from: date("2026-09-24 04:57", la.identifier), minutes: 15, forward: true, in: la), la.identifier) == "05:00 PDT")
        #expect(wall(MapScrub.step(from: date("2026-09-24 05:00", la.identifier), minutes: 15, forward: false, in: la), la.identifier) == "04:45 PDT")
        // 印度的整点是 UTC 的半点：按本机钟面对齐，不按 UTC。
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let india = MapScrub.step(from: date("2026-09-24 10:10", kolkata.identifier), minutes: 60, forward: true, in: kolkata)
        #expect(india == date("2026-09-24 11:00", kolkata.identifier))
        // 换钟：春天 1:30 PST → 3:00 PDT（2:00 不存在）；秋天 1:30 PDT → 1:00 PST（重复的那个 1 点），都不走回头路。
        #expect(wall(MapScrub.step(from: date("2026-03-08 01:30", la.identifier), minutes: 60, forward: true, in: la), la.identifier) == "03:00 PDT")
        let fallBack = date("2026-11-01 00:30", la.identifier).addingTimeInterval(3600)   // 1:30 PDT
        #expect(wall(MapScrub.step(from: fallBack, minutes: 60, forward: true, in: la), la.identifier) == "01:00 PST")

        // 性质：七个时区（含半点、45 分、豪勋爵岛的半小时夏令时）、一年里 400 个起点、两种步长、两个方向。
        let ids = ["America/Los_Angeles", "Europe/London", "Asia/Kolkata", "Asia/Kathmandu", "Australia/Lord_Howe", "Pacific/Chatham", "America/St_Johns"]
        let start = date("2026-01-01 00:00", "UTC")
        for id in ids {
            let zone = TimeZone(identifier: id)!
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            for k in 0..<400 {
                let from = start.addingTimeInterval(Double(k) * 78_913.7)   // 约 22 小时的非整数间隔，扫遍一年各个钟点
                for minutes in [60, 15] {
                    for forward in [true, false] {
                        let to = MapScrub.step(from: from, minutes: minutes, forward: forward, in: zone)
                        let delta = to.timeIntervalSince(from) * (forward ? 1 : -1)
                        #expect(delta > 0 && delta <= Double(minutes * 60 + 3600), "\(id) \(from) \(minutes) \(forward) 走了 \(delta) 秒")
                        let minute = calendar.component(.minute, from: to), second = calendar.component(.second, from: to)
                        #expect(second == 0 && minute % minutes == 0, "\(id) \(from) → \(wall(to, id)) 没对齐")
                    }
                }
            }
        }
    }

    /// 「拷贝地图图片」：一张 1200 × 460 pt 的海报、2 倍像素（2400 × 920），能编成 PNG；
    /// 图本身就是海报（没有深色边框），四个角是地图上的天色，不是同一个底色。
    @MainActor @Test func mapImageIsAPosterAtTwiceItsSize() throws {
        let places = [WorldMapPlace(latitude: 34.05, longitude: -118.24, home: true), WorldMapPlace(latitude: 35.68, longitude: 139.69, home: false)]
        let input = EarthPoster.Input(instant: Date(timeIntervalSince1970: 1_789_542_000), places: places,
                                                   labels: [MapLabel(name: "洛杉矶", time: "04:00"), MapLabel(name: "东京", time: "20:00")],
                                                   caption: "洛杉矶 · 9月24日 星期四 04:00", locale: Locale(identifier: "zh-Hans"))
        let png = try #require(EarthPoster.data(input))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == Int(EarthPoster.width * 2))
        #expect(bitmap.pixelsHigh == Int(EarthPoster.height * 2))
        #expect(EarthPoster.height == 460)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        var corners = Set<[Int]>()
        for (x, y) in [(2, 2), (bitmap.pixelsWide - 3, 2), (2, bitmap.pixelsHigh - 3), (bitmap.pixelsWide - 3, bitmap.pixelsHigh - 3)] {
            var pixel = [Int](repeating: 0, count: 4)
            bitmap.getPixel(&pixel, atX: x, y: y)
            corners.insert(Array(pixel.prefix(3)))
        }
        #expect(corners.count > 1, "四角 \(corners)")
        // 看图用：`TEST_RUNNER_MEANTIME_POSTER_OUT=1` 时把中英两种题字的海报各存一张到测试宿主的临时目录（沙盒里只能写那里），路径打在输出里。
        if ProcessInfo.processInfo.environment["MEANTIME_POSTER_OUT"] == "1" {
            let out = FileManager.default.temporaryDirectory.path
            print("MEANTIME_POSTER_DIR=\(out)")
            for (language, instant) in [("zh-Hans", 1_789_542_000.0), ("en", 1_790_000_000.0)] {
                let poster = EarthPoster.Input(instant: Date(timeIntervalSince1970: instant), places: places,
                                               labels: [MapLabel(name: language == "en" ? "Los Angeles" : "洛杉矶", time: "04:00"),
                                                        MapLabel(name: language == "en" ? "Tokyo" : "东京", time: "20:00")],
                                               caption: "Los Angeles · 04:00", locale: Locale(identifier: language))
                try EarthPoster.data(poster)?.write(to: URL(fileURLWithPath: out).appendingPathComponent("poster-\(language).png"))
            }
        }
    }

    @MainActor @Test func posterClipboardWritesPNGAndRendersTIFFOnlyOnDemand() throws {
        let input = EarthPoster.Input(instant: Date(timeIntervalSince1970: 1_789_542_000), places: [], labels: [],
                                      caption: "Frozen moment", locale: Locale(identifier: "en"))
        let pasteboard = NSPasteboard(name: .init("com.dayside.tests.poster.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(EarthPoster.copy(input, pasteboard: pasteboard))
        let png = try #require(pasteboard.data(forType: .png))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let item = NSPasteboardItem()
        let provider = EarthPoster.TIFFProvider(input: input)
        #expect(provider.renderCount == 0)
        provider.pasteboard(pasteboard, item: item, provideDataForType: .png)
        #expect(provider.renderCount == 0)
        provider.pasteboard(pasteboard, item: item, provideDataForType: .tiff)
        #expect(provider.renderCount == 1)
        let tiff = try #require(item.data(forType: .tiff))
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        #expect(bitmap.pixelsWide == 2400 && bitmap.pixelsHigh == 920)
        let requested = try #require(pasteboard.data(forType: .tiff))
        #expect(NSBitmapImageRep(data: requested)?.pixelsWide == 2400)
        let image = try #require(NSImage(pasteboard: pasteboard))
        #expect(image.representations.contains { $0.pixelsWide == 2400 && $0.pixelsHigh == 920 })
    }

    /// 「指到哪儿看哪儿几点」：指针下的点换成经纬度用的投影与 Rust 画点用的是同一套（拿 `worldmap.scene` 的 pin 当判据），
    /// 正对名古屋得名古屋，东京东边 8 pt 的海上仍是东京，指在已添加的东京上标成「已是地点」，太平洋中间什么都不答。
    @Test func pointingAtACityFindsItAndKnowsWhenItIsAlreadyAPlace() throws {
        let size = CGSize(width: 900, height: 450)
        for (lat, lon) in [(35.18, 136.91), (51.5, -0.13), (-33.87, 151.21), (64.14, -21.94), (-54.8, -68.3)] {
            let scene = WorldMapScene.scene(instant: Date(timeIntervalSince1970: 1_789_542_000), size: size,
                                            places: [WorldMapPlace(latitude: lat, longitude: lon, home: false)])
            let pin = try #require(scene.pins.first)
            let point = MapProbe.point(latitude: lat, longitude: lon, in: size, latitudes: -90...90)
            #expect(abs(point.x - pin.x) < 0.5 && abs(point.y - pin.y) < 0.5, "(\(lat), \(lon)) 投影 \(point) ≠ Rust \(pin)")
            let back = try #require(MapProbe.coordinate(of: point, in: size, latitudes: -90...90))
            #expect(abs(back.latitude - lat) < 1e-9 && abs(back.longitude - lon) < 1e-9)
        }
        let nagoya = MapProbe.point(latitude: 35.18, longitude: 136.91, in: size, latitudes: -90...90)
        let hit = MapProbe.lookup(at: nagoya, in: size, latitudes: -90...90, zones: []) { _, record in record.name }
        #expect(hit?.record.name == "Nagoya")
        #expect(hit?.record.timezoneID == "Asia/Tokyo")
        #expect(hit?.isPlace == false)
        // 东京的势力范围大：指在它东边 8 pt 的海上还是东京。
        let offTokyo = MapProbe.point(latitude: 35.69, longitude: 139.69 + 8 * 360 / 900, in: size, latitudes: -90...90)
        #expect(MapProbe.lookup(at: offTokyo, in: size, latitudes: -90...90, zones: []) { _, record in record.name }?.record.name == "Tokyo")
        let tokyoPlace = TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo", coordinate: Coordinate(latitude: 35.6895, longitude: 139.69171))
        let tokyo = MapProbe.point(latitude: 35.69, longitude: 139.69, in: size, latitudes: -90...90)
        #expect(MapProbe.lookup(at: tokyo, in: size, latitudes: -90...90, zones: [tokyoPlace]) { _, record in record.name }?.isPlace == true)
        let pacific = MapProbe.point(latitude: 0, longitude: -150, in: size, latitudes: -90...90)
        #expect(MapProbe.lookup(at: pacific, in: size, latitudes: -90...90, zones: []) { _, record in record.name } == nil)
    }

    @MainActor @Test func earthCopyCommandWorksWithItsToolbarHidden() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "earth-copy-command")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = .en
        let pasteboard = NSPasteboard(name: .init("com.dayside.tests.earth-command.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let controller = NSHostingController(rootView: EarthView(copyPasteboard: pasteboard)
            .environment(model).environment(model.core)
            .environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 960, height: 418))
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            model.setEarthVisible(false)
        }
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutSubtreeIfNeeded()
        let toolbar = try #require(window.toolbar, "真实地球窗必须提供工具栏")
        toolbar.isVisible = false
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        try #require(window.makeFirstResponder(controller.view))
        let responderName = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        print("EARTH_COPY_FOCUS appActive=\(NSApp.isActive) canBecomeKey=\(window.canBecomeKey) key=\(window.isKeyWindow) responder=\(responderName)")
        #expect(!toolbar.isVisible)
        let responder = try #require(window.firstResponder as? NSView)
        try #require(responder === controller.view || responder.isDescendant(of: controller.view),
                     "焦点必须在真实地球视图内")
        // Follow the Earth view responder chain without making its window key.
        try #require(responder.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        let png = try #require(pasteboard.data(forType: .png))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 2400 && bitmap.pixelsHigh == 920)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MEANTIME_UI_TEST_FOREGROUND"] == "1",
        "Native fullscreen focused Dayside during a monitored quiet run; use the strict idle foreground lane."))
    func earthCopyCommandWorksInNativeFullscreen() async throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "earth-fullscreen-command")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false, applySystemIntegration: false)
        model.settings.interfaceLanguage = .en
        let pasteboard = NSPasteboard(name: .init("com.dayside.tests.earth-fullscreen.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let controller = NSHostingController(rootView: EarthView(copyPasteboard: pasteboard)
            .environment(model).environment(model.core)
            .environment(\.locale, Locale(identifier: "en")))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setContentSize(NSSize(width: 960, height: 418))
        let transition = EarthFullscreenTransition()
        let entered = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                              object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                transition.entered = true
                print("EARTH_NATIVE_LIFECYCLE did-enter-fullscreen")
            }
        }
        let exited = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                             object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                transition.exited = true
                print("EARTH_NATIVE_LIFECYCLE did-exit-fullscreen")
            }
        }
        defer {
            NotificationCenter.default.removeObserver(entered)
            NotificationCenter.default.removeObserver(exited)
        }
        func closeWindow() async {
            if transition.entered && !transition.exited {
                if !transition.exitRequested {
                    transition.exitRequested = true
                    print("EARTH_NATIVE_LIFECYCLE cleanup-request-exit")
                    window.toggleFullScreen(nil)
                }
                for _ in 0..<100 {
                    if transition.exited { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                #expect(transition.exited, "清理窗口前必须完成退出全屏")
            }
            #expect(!window.styleMask.contains(.fullScreen), "不能拆掉仍在全屏中的视图")
            #expect(!transition.entryRequested || transition.exited, "进入全屏的请求必须完成退出后才能清理")
            guard (!transition.entryRequested || transition.exited), !window.styleMask.contains(.fullScreen) else { return }
            print("EARTH_NATIVE_LIFECYCLE before-close exited=\(transition.exited)")
            window.close()
            print("EARTH_NATIVE_LIFECYCLE after-close")
            await Task.yield()
            print("EARTH_NATIVE_LIFECYCLE before-content-detach")
            window.contentViewController = nil
            print("EARTH_NATIVE_LIFECYCLE after-content-detach")
            model.setEarthVisible(false)
        }
        do {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            transition.entryRequested = true
            print("EARTH_NATIVE_LIFECYCLE request-enter")
            window.toggleFullScreen(nil)
            for _ in 0..<100 {
                if transition.entered { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(transition.entered, "必须等系统完成进入全屏")
            try #require(window.styleMask.contains(.fullScreen), "必须进入系统全屏，不能以手动隐藏工具栏代替")
            // Allow the queued fullscreen view updates to run before hiding the toolbar.
            try await Task.sleep(for: .milliseconds(100))
            let toolbar = try #require(window.toolbar)
            toolbar.isVisible = false
            window.displayIfNeeded()
            try #require(!toolbar.isVisible)
            window.makeKey()
            controller.view.layoutSubtreeIfNeeded()
            try #require(window.isKeyWindow)
            let responder = try #require(window.firstResponder as? NSView)
            try #require(responder === controller.view || responder.isDescendant(of: controller.view))
            // 系统全屏内从真实响应链发命令，不构造按键或点击。
            try #require(NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil))
            let png = try #require(pasteboard.data(forType: .png))
            let bitmap = try #require(NSBitmapImageRep(data: png))
            #expect(bitmap.pixelsWide == 2400 && bitmap.pixelsHigh == 920)
            print("EARTH_NATIVE_FULLSCREEN frame=\(window.frame) content=\(controller.view.bounds) toolbarVisible=\(toolbar.isVisible) pngBytes=\(png.count)")
            transition.exitRequested = true
            print("EARTH_NATIVE_LIFECYCLE request-exit")
            window.toggleFullScreen(nil)
            for _ in 0..<100 {
                if transition.exited { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(transition.exited)
            #expect(!window.styleMask.contains(.fullScreen))
        } catch {
            await closeWindow()
            throw error
        }
        await closeWindow()
        print("EARTH_NATIVE_LIFECYCLE test-body-return")
    }

    /// 地图标签跨日时与面板行同一套：本机洛杉矶 17:00 时东京已是次日 9:00、檀香山仍是同一天；
    /// 本机东京 8:00 时洛杉矶还是前一日 16:00。英文按目录写成「9:00 next day」。判据是 `Calendar` 各自读出的日。
    @MainActor @Test func mapClockMarksTheNextAndPreviousDayLikePanelRows() {
        let la = TimeZone(identifier: "America/Los_Angeles")!, tokyo = TimeZone(identifier: "Asia/Tokyo")!, honolulu = TimeZone(identifier: "Pacific/Honolulu")!
        let evening = Date(timeIntervalSince1970: 1_790_294_400)   // 2026-09-24 17:00 PDT = 2026-09-25 09:00 JST
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = la; let homeDay = calendar.component(.day, from: evening)
        calendar.timeZone = tokyo; let tokyoDay = calendar.component(.day, from: evening)
        #expect(tokyoDay == homeDay + 1)
        let zh = Locale(identifier: "zh-Hans"), en = Locale(identifier: "en")
        let tokyoZH = WorldMapView.clock(evening, in: tokyo, hourStyle: .force24, locale: zh, reference: la)
        let tokyoEN = WorldMapView.clock(evening, in: tokyo, hourStyle: .force24, locale: en, reference: la)
        #expect(tokyoZH == "次日 9:00", "\(tokyoZH)")
        #expect(tokyoEN == "9:00 next day", "\(tokyoEN)")
        #expect(WorldMapView.clock(evening, in: honolulu, hourStyle: .force24, locale: zh, reference: la) == "14:00")
        let morning = Date(timeIntervalSince1970: 1_790_204_400)   // 2026-09-24 08:00 JST = 2026-09-23 16:00 PDT
        #expect(WorldMapView.clock(morning, in: la, hourStyle: .force24, locale: zh, reference: tokyo) == "前一日 16:00")
    }

    /// 地球窗月亮下写的月相名：八个名字（与天文页同一套键）在十六种界面语言里都有译文，英文不是中文键原样退回。
    @MainActor @Test func everyMoonPhaseHasANameInEveryLanguage() {
        let keys = WorldMapScene.moonPhases.map(WorldMapScene.moonPhaseKey)
        #expect(Set(keys).count == 8)
        for language in ["en", "ja", "ko", "zh-Hant", "de", "es", "fr", "pt-BR", "ru", "it", "nl", "pl", "tr", "vi", "id"] {
            let names = WorldMapScene.phaseNames(locale: Locale(identifier: language))
            #expect(names.count == 8)
            for (phase, name) in names {
                // 日文与繁体中文有几个月相名本来就与中文键同形（新月、上弦月）；其余语言与键相同就是没有译文。
                #expect(name != WorldMapScene.moonPhaseKey(phase) || ["ja", "zh-Hant"].contains(language), "\(language) \(phase) 没有译文")
            }
        }
    }
}
