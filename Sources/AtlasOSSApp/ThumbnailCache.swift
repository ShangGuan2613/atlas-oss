import Foundation

/// Bounded LRU cache with a count limit *and* a byte budget.
///
/// P1f replaces the old `NSCache` so eviction is deterministic and testable: a grid that
/// scrolls past 10k items must keep the *most recently seen* tiles, and the memory ceiling
/// has to be a number we can state in `STATUS.md` rather than "whatever `NSCache` decides".
///
/// Deliberately tiny: a dictionary plus an access-order array. At the sizes involved
/// (hundreds of entries) the O(n) array reordering is far cheaper than a linked list's
/// pointer chasing, and the whole thing stays auditable in one screen.
final class LRUCache<Key: Hashable, Value> {

    let countLimit: Int
    let costLimit: Int

    private var storage: [Key: Value] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var costs: [Key: Int] = [:]
    private var totalCost = 0
    private let lock = NSLock()

    init(countLimit: Int, costLimit: Int = .max) {
        self.countLimit = max(1, countLimit)
        self.costLimit = max(0, costLimit)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var currentCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCost
    }

    /// Keys in LRU order (oldest first) — for eviction tests and diagnostics.
    var orderedKeys: [Key] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    /// Cache hit. A hit promotes the entry to most-recently-used.
    func value(forKey key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// Membership test that does **not** promote — so a probe never distorts eviction order.
    func contains(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] != nil
    }

    func insert(_ value: Value, forKey key: Key, cost: Int = 0) {
        lock.lock()
        defer { lock.unlock() }

        let newCost = max(0, cost)
        if storage[key] != nil {
            totalCost -= costs[key] ?? 0
            totalCost += newCost
            costs[key] = newCost
            storage[key] = value
            touch(key)
        } else {
            storage[key] = value
            costs[key] = newCost
            totalCost += newCost
            order.append(key)
        }
        evictIfNeeded()
    }

    func remove(_ key: Key) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(key)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        costs.removeAll()
        order.removeAll()
        totalCost = 0
    }

    // MARK: - Internals

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else {
            order.append(key)
            return
        }
        order.remove(at: index)
        order.append(key)
    }

    private func removeLocked(_ key: Key) {
        guard storage.removeValue(forKey: key) != nil else { return }
        totalCost -= costs.removeValue(forKey: key) ?? 0
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
    }

    private func evictIfNeeded() {
        while order.count > countLimit || (totalCost > costLimit && order.count > 1) {
            guard let oldest = order.first else { return }
            removeLocked(oldest)
        }
    }
}
