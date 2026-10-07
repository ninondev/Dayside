// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation
import Testing
@testable import TahoeTime

@MainActor
enum SharedClockEvents {
    /// 观察真正的时间变化；超时后取消并等观察任务退出。
    static func next(in core: TimeCore, after baseline: Date,
                     deadline: Duration = .seconds(120)) async -> Date? {
        await withTaskGroup(of: Date?.self) { group in
            group.addTask { @MainActor in
                for await date in Observations({ core.now }) {
                    if Task.isCancelled { return nil }
                    if date != baseline { return date }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

@MainActor
struct SharedClockEventTests {
    @Test(.timeLimit(.minutes(5)))
    func eitherWindowReceivesTicksAndClosingBothStopsThem() async {
        let handle = TestDefaults.make(prefix: "dayside.shared-clock.events")
        Store.saveZones([
            TimeZoneEntry(timezoneID: "Europe/London", cityName: "London"),
            TimeZoneEntry(timezoneID: "Asia/Tokyo", cityName: "Tokyo"),
            TimeZoneEntry(timezoneID: "America/Los_Angeles", cityName: "Los Angeles")
        ], to: handle.defaults)
        let model = AppModel(defaults: handle.defaults, migrate: false,
                             applySystemIntegration: false)
        let hub = FeatureHub(defaults: handle.defaults)
        defer {
            hub.setVisible(false)
            model.setPanelVisible(false)
            handle.cleanup()
        }
        hub.attach(to: model)
        model.settings.showSeconds = true
        model.setPanelVisible(true)
        hub.setVisible(true)
        hub.setVisible(false)
        let panelOnly = model.now
        _ = await SharedClockEvents.next(in: model.core, after: panelOnly)
        #expect(model.now > panelOnly)
        hub.setVisible(true)
        model.setPanelVisible(false)
        let workspaceOnly = model.now
        _ = await SharedClockEvents.next(in: model.core, after: workspaceOnly)
        #expect(model.now > workspaceOnly)
        hub.setVisible(false)
        let closed = model.now
        let unwantedTick = await SharedClockEvents.next(in: model.core, after: closed,
                                                        deadline: .milliseconds(1150))
        #expect(unwantedTick == nil)
        #expect(model.now == closed)
        #expect(hub.activeResourceCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func anIdleObservationEndsAtItsDeadlineAndOnCancellation() async {
        let core = TimeCore(zones: [], settings: AppSettings())
        let baseline = core.now
        #expect(await SharedClockEvents.next(in: core, after: baseline,
                                             deadline: .milliseconds(20)) == nil)
        let waiting = Task {
            await SharedClockEvents.next(in: core, after: baseline)
        }
        await Task.yield()
        waiting.cancel()
        #expect(await waiting.value == nil)
    }
}
