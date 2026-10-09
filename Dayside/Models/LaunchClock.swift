// SPDX-License-Identifier: GPL-3.0-only
//
//  LaunchClock.swift
//  Dayside
//
//  进程从 exec 起过了多少秒（系统事实：内核记的进程启动时刻）。只给发布门 / 峰值量尺把启动拆段用：
//  exec → App.init 是 dyld 加载与静态初始化，App.init → 菜单栏就绪是我们自己的代码。
//

import Darwin
import Foundation

nonisolated enum LaunchClock {
    static func secondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return .nan }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }
}
