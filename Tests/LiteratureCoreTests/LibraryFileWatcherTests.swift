import Foundation
@testable import LiteratureCore

// MARK: - 更新 LibraryFileWatcher 测试

enum LibraryFileWatcherSuite {
    /// 线程安全回调收集器。
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[URL]] = []
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return batches.count
        }
        var all: [URL] {
            lock.lock(); defer { lock.unlock() }
            return batches.flatMap { $0 }
        }
        func add(_ urls: [URL]) {
            lock.lock(); batches.append(urls); lock.unlock()
        }
        func waitFor(_ n: Int, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if count >= n { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return count >= n
        }
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "LibraryFileWatcher", name: "syntheticEventsAggregateAndFilter") {
                let dir = Fixtures.makeTempDir("watch-syn")
                defer { Fixtures.cleanup(dir) }
                let collector = Collector()
                let watcher = LibraryFileWatcher(roots: [dir], debounce: 0.2) { urls in
                    collector.add(urls)
                }
                // 真实存在文件（settle 存在性过滤要求存活件）。
                try Data("x".utf8).write(to: dir.appendingPathComponent("book1.pdf"))
                try Data("y".utf8).write(to: dir.appendingPathComponent("notes.txt"))
                try Data("z".utf8).write(to: dir.appendingPathComponent("index.db"))
                try Data("w".utf8).write(to: dir.appendingPathComponent("fulltext.db-wal"))
                watcher.testInjectEvents([
                    dir.appendingPathComponent("book1.pdf").path,
                    dir.appendingPathComponent("notes.txt").path,          // 非 pdf：滤
                    dir.appendingPathComponent("index.db").path,           // 自有存储：滤
                    dir.appendingPathComponent("fulltext.db-wal").path,    // 自有存储：滤
                ])
                try expectTrue(watcher.testWaitForSettle(timeout: 5), "debounce window elapses")
                try expectTrue(collector.waitFor(1, timeout: 5), "one settle callback")
                let batch = collector.all
                try expectEqual(batch.count, 1, "txt and storage files filtered out")
                try expectEqual(batch.first?.lastPathComponent, "book1.pdf")
            },

            TestDesc(suite: "LibraryFileWatcher", name: "debounceMergesBurstIntoOneSettle") {
                let dir = Fixtures.makeTempDir("watch-debounce")
                defer { Fixtures.cleanup(dir) }
                let collector = Collector()
                let watcher = LibraryFileWatcher(roots: [dir], debounce: 0.4) { urls in
                    collector.add(urls)
                }
                try Data("1".utf8).write(to: dir.appendingPathComponent("a.pdf"))
                try Data("2".utf8).write(to: dir.appendingPathComponent("b.pdf"))
                // 三连发（间隔 < debounce）：每次都重置防抖计时。
                for name in ["a.pdf", "b.pdf", "a.pdf"] {
                    watcher.testInjectEvents([dir.appendingPathComponent(name).path])
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try expectTrue(watcher.testWaitForSettle(timeout: 5))
                try expectTrue(collector.waitFor(1, timeout: 5))
                // 宽限窗：确认没有第二拍。
                try await Task.sleep(nanoseconds: 600_000_000)
                try expectEqual(collector.count, 1, "burst merged into exactly one settle")
                try expectEqual(Set(collector.all.map { $0.lastPathComponent }), Set(["a.pdf", "b.pdf"]))
            },

            TestDesc(suite: "LibraryFileWatcher", name: "vanishingPathNotDelivered") {
                let dir = Fixtures.makeTempDir("watch-vanish")
                defer { Fixtures.cleanup(dir) }
                let collector = Collector()
                let watcher = LibraryFileWatcher(roots: [dir], debounce: 0.2) { urls in
                    collector.add(urls)
                }
                let ghost = dir.appendingPathComponent("ghost.pdf")
                try Data("g".utf8).write(to: ghost)
                watcher.testInjectEvents([ghost.path])
                try FileManager.default.removeItem(at: ghost)   // settle 前删除
                try expectTrue(watcher.testWaitForSettle(timeout: 5))
                try await Task.sleep(nanoseconds: 400_000_000)
                try expectEqual(collector.count, 0, "vanished path filtered at settle")
            },

            TestDesc(suite: "LibraryFileWatcher", name: "realFileWriteDeliversAndStopSilences") {
                let dir = Fixtures.makeTempDir("watch-real")
                defer { Fixtures.cleanup(dir) }
                let collector = Collector()
                let watcher = LibraryFileWatcher(roots: [dir], debounce: 0.5) { urls in
                    collector.add(urls)
                }
                watcher.start()
                try expectTrue(watcher.isWatching, "watching after start")
                defer { watcher.stop() }
                try Data("real".utf8).write(to: dir.appendingPathComponent("real.pdf"))
                let got = collector.waitFor(1, timeout: 15)
                try expectTrue(got,
                               "real FSEvents event not delivered within 15s（合成路径已由其他断言覆盖；"
                               + "若复现请核查门禁环境卷/沙盒对 FSEvents 的支持）")
                try expectTrue(collector.all.contains { $0.lastPathComponent == "real.pdf" })
                watcher.stop()
                try expectFalse(watcher.isWatching, "not watching after stop")
                try Data("after".utf8).write(to: dir.appendingPathComponent("after.pdf"))
                try await Task.sleep(nanoseconds: 1_500_000_000)
                try expectEqual(collector.count, 1, "no callback after stop")
            },
        ]
    }
}
