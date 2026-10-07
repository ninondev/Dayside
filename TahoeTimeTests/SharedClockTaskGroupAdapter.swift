// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension TaskGroup where ChildTaskResult == Date? {
    /// 明确子任务闭包可发送，保留闭包原来的执行器。
    nonisolated mutating func addTask(operation: @escaping @isolated(any) @Sendable () async -> Date?) {
        addTask(priority: nil) {
            await operation()
        }
    }
}
