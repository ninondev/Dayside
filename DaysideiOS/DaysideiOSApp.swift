// SPDX-License-Identifier: GPL-3.0-only
//
//  DaysideiOSApp.swift
//  DaysideiOS
//
//  iPhone 原型：同一份 Rust 核心（城市索引、
//  搜索折叠、时区目录）与同一批 Foundation 模型文件，只有视图是 iOS 的。不读 macOS 版的数据，不做同步，
//  不含任何 Pro / 日历 / 通讯录面——它回答的只是「这套核心在 iPhone 上能不能跑、跑起来什么样」。
//

import SwiftUI

@main
struct DaysideiOSApp: App {
    var body: some Scene {
        WindowGroup {
            WorldClockView()
        }
    }
}
