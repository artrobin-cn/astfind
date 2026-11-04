import Foundation

/// 同来源内容抽取执行门（M0.6）。
///
/// 只限制“实际执行 `runPending` 批次”，不阻塞 `enqueuePending`/`limit=0` 入队。
/// 后到触发快速返回，不排队等待，避免 ready 事件叠加出多批 OCR 线程。
final class ContentBatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var wildcardActive = false
    private var activeSources: Set<String> = []

    /// nil 表示全局批次，与任何来源互斥。
    func tryAcquire(_ sourceId: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let sourceId {
            guard !wildcardActive, !activeSources.contains(sourceId) else { return false }
            activeSources.insert(sourceId)
        } else {
            guard !wildcardActive, activeSources.isEmpty else { return false }
            wildcardActive = true
        }
        return true
    }

    func release(_ sourceId: String?) {
        lock.lock(); defer { lock.unlock() }
        if let sourceId { activeSources.remove(sourceId) }
        else { wildcardActive = false }
    }

    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeSources.count + (wildcardActive ? 1 : 0)
    }
}
