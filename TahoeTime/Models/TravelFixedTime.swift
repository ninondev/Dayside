// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 旅行页「固定时刻」。它是设置里的一个字段（Rust `settings.rs`
/// 归一化），换算与旅行页共用。
struct TravelFixedTime: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var label: String
    /// 家里那边的墙钟分钟（0 ..< 1440）。
    var minute: Int
}
