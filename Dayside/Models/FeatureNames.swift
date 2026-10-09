// SPDX-License-Identifier: GPL-3.0-only

/// 页面与自动化共用的功能标识。
enum DaysideFeature: String, CaseIterable, Sendable {
    case planner, agenda, people, timers, travel
    case convert, copy, shortcuts, dstWatch, astronomy, sharing, markets
}
