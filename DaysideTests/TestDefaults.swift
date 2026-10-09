// SPDX-License-Identifier: GPL-3.0-only
//
//  TestDefaults.swift
//  DaysideTests
//
//  一次性 UserDefaults suite 的共用助手。
//
//  历史上每个用例各自拼 "<前缀>.\(UUID.uuidString)" 建 suite,多数会在测试结束调
//  removePersistentDomain(forName:),但 cfprefsd 仍把(此时已清空的)plist 文件留在磁盘——
//  App 容器 Library/Preferences/ 里因此累计了数千个残留文件。这里统一生成 suite 名,
//  清理时把文件本身也删掉。实际的文件删除逻辑只有一份,在 ApplicationSession.discardOneOffSuite(named:)
//  (Dayside 目标,`@testable import` 复用);测试宿主自己的一次性域(ApplicationSession.defaults)
//  退出时也走同一份实现,见该文件。
//

import Foundation
import Synchronization
@testable import Dayside

enum TestDefaults {
    /// 只给一个独立、每次不同的 suite 名与清理动作——供需要自己构造 UserDefaults(或其子类,
    /// 如权益测试的 CacheReadSpy)的调用方使用。
    static func makeSuiteName(prefix: String) -> (name: String, cleanup: () -> Void) {
        let name = "\(prefix).\(UUID().uuidString)"
        return (name, { ApplicationSession.discardOneOffSuite(named: name) })
    }

    /// 常规用法:一次性 UserDefaults 加对应清理动作。用例需要连 suite 名本身也核对
    /// (如 SharingTests 要 persistentDomain(forName:))时改用 `makeSuiteName(prefix:)`
    /// 自己构造 UserDefaults,见该用法。
    /// 清理 = removePersistentDomain(forName:) + 删除 cfprefsd 留在磁盘上的 plist;
    /// 删文件失败(文件已不存在、沙盒权限等)不应让测试失败,静默忽略——见
    /// ApplicationSession.discardOneOffSuite(named:)。
    static func make(prefix: String) -> (defaults: UserDefaults, cleanup: () -> Void) {
        let (name, cleanup) = makeSuiteName(prefix: prefix)
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("UserDefaults(suiteName:) 初始化失败: \(name)")
        }
        return (defaults, cleanup)
    }
}

/// 数 `bool(forKey:)` 被读了几次的 UserDefaults（权益缓存与其它「启动只读一次」的断言用）。
nonisolated final class CacheReadSpy: UserDefaults {
    private let reads = Mutex(0)
    var cacheReadCount: Int { reads.withLock { $0 } }

    override func bool(forKey defaultName: String) -> Bool {
        reads.withLock { $0 += 1 }
        return false
    }
}
