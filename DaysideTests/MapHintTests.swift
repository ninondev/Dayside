// SPDX-License-Identifier: GPL-3.0-only
//
//  MapHintTests.swift
//  Dayside
//
//  地图手势「学一次」：面板前五次亮「地图也能拖」，拖一次立刻熄、永不再亮；
//  两个计数落盘、封顶 99（Rust 那一侧的默认与夹取由 settings::map_hint_counters_default_and_clamp 钉住）。
//

import Foundation
import Testing
@testable import Dayside

@MainActor
struct MapHintTests {

    /// 开面板六次不拖：第 1–5 次亮提示、第 6 次不亮；mapHintOpens 落到 5，重开 AppModel 还在。
    @Test func hintShowsOnFirstFiveOpensOnlyAndPersists() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "maphint")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false)
        for open in 1...6 {
            model.setPanelVisible(false)
            model.setPanelVisible(true)
            #expect(model.showsMapHint == (open <= 5))
        }
        #expect(model.settings.mapHintOpens == 5)
        #expect(model.settings.mapDrags == 0)
        let reloaded = AppModel(defaults: defaults, migrate: false)
        #expect(reloaded.settings.mapHintOpens == 5)
        #expect(reloaded.settings.mapDrags == 0)
    }

    /// 拖一次（noteMapDrag）：提示立刻熄；之后开面板永不再亮；mapDrags 落盘且封顶 99。
    @Test func oneDragRetiresTheHintForeverAndCapsAt99() throws {
        let (defaults, cleanup) = TestDefaults.make(prefix: "maphint")
        defer { cleanup() }
        let model = AppModel(defaults: defaults, migrate: false)
        model.setPanelVisible(true)
        #expect(model.showsMapHint)
        model.noteMapDrag()
        #expect(!model.showsMapHint)
        #expect(model.settings.mapDrags == 1)
        model.setPanelVisible(false)
        model.setPanelVisible(true)
        #expect(!model.showsMapHint)
        for _ in 0..<200 { model.noteMapDrag() }
        #expect(model.settings.mapDrags == 99)
        let reloaded = AppModel(defaults: defaults, migrate: false)
        #expect(reloaded.settings.mapDrags == 99)
        #expect(reloaded.settings.mapHintOpens == 1)
        reloaded.setPanelVisible(false)
        reloaded.setPanelVisible(true)
        #expect(!reloaded.showsMapHint)
    }
}
