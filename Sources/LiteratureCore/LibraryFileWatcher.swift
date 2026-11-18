import Foundation
#if os(macOS)
import CoreServices

// MARK: - 文件事件驱动增量索引器

public final class LibraryFileWatcher: @unchecked Sendable {
    /// 监听根目录列表（App 侧接线与 exclusions.json 同源 root 列表）。
    public let roots: [URL]
    /// 防抖窗（秒）：最后事件后静默满窗才 settle。
    public let debounce: TimeInterval
    /// settle 回调（一次性交出全部变更路径；事件队列线程调用，调用方自转）。
    private let onSettle: @Sendable ([URL]) -> Void

    /// 全部可变状态由本锁守护（pending/timer/stream/watching/contextInfo）；
    /// 事件串行队列只负责线程归属，互斥统一走锁。
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var contextInfo: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?
    private var pending: Set<String> = []
    private var watching = false
    /// 事件处理串行队列（FSEvents 回调与防抖计时共用）。
    private let queue: DispatchQueue

    public init(roots: [URL], debounce: TimeInterval = 5.0,
                onSettle: @escaping @Sendable ([URL]) -> Void) {
        self.roots = roots
        self.debounce = debounce
        self.onSettle = onSettle
        self.queue = DispatchQueue(label: "literature.library-file-watcher")
    }

    public var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return watching
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !watching, !roots.isEmpty else { return }
        // Unmanaged 生命周期：passRetained 把 +1 交给 context.info（流存活
        // 期间自持）；stop 成功路径释放平衡。回调内一律 takeUnretained。
        let info = Unmanaged.passRetained(self).toOpaque()
        contextInfo = info
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let paths = roots.map { $0.path }
        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, eventIds in
            guard let clientInfo else { return }
            let watcher = Unmanaged<LibraryFileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let count = Int(numEvents)
            var arrived: [String] = []
            arrived.reserveCapacity(count)
            // CFArrayRef 仅回调期内有效且为 +0（框架所有）——全程 CF API 直读
            //（Unmanaged + CFGet，零 ARC 参与、零 ObjC 消息）。
            // 根因（独立复现）：start 原先
            // 未设 kFSEventStreamCreateFlagUseCFTypes——FSEvents.h:214-219 明文
            // 无此旗标时 eventPaths 是裸 C 数组（char**），此前一律按
            // CFArrayRef/NSArray 解读＝从首个回调起就读垃圾（SIGSEGV，
            // objc_msgSend 野指针；端到端测试 5/5 必现，与 ARC 无关）。
            let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let delivered = CFArrayGetCount(cfArray)
            for i in 0..<min(delivered, count) {
                guard let value = CFArrayGetValueAtIndex(cfArray, i) else { continue }
                let path = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
                arrived.append(path)
            }
            _ = eventFlags; _ = eventIds   // FileEvents 旗标下路径即文件级
            watcher.handleEvents(arrived)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,   // 内核侧合流窗（秒）；5 秒 settle 防抖在应用层
            // UseCFTypes 必设：无它 eventPaths 是裸 C 数组（char**）而非
            // CFArrayRef（FSEvents.h:214-219）——缺失即回调首事件读垃圾崩
            //（见回调注释）。
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                   | kFSEventStreamCreateFlagNoDefer)) else {
            // 创建失败：释放自持引用，保持未监听态（isWatching 如实 false）。
            Unmanaged<LibraryFileWatcher>.fromOpaque(info).release()
            contextInfo = nil
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            Unmanaged<LibraryFileWatcher>.fromOpaque(info).release()
            contextInfo = nil
            return
        }
        watching = true
    }

    public func stop() {
        lock.lock()
        let stream = self.stream
        let info = self.contextInfo
        self.stream = nil
        self.contextInfo = nil
        watching = false
        lock.unlock()
        // 流停＋防抖计时清。
        if let stream {
            FSEventStreamStop(stream)
            // Invalidate/Release（连同 passRetained 自持引用的释放）排到流
            // 自己的串行队列：与在途回调同队序列化——回调持有的 eventPaths
            // （CF 数组，流所有）与 clientInfo 必须活过回调全程；在调用线程
            // 直接 Release 会与在途回调竞态、数组被提前释放（.ips 崩溃栈实证：
            // objc_msgSend 野指针 @ FSEvents 回调）。
            queue.async {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                if let info {
                    Unmanaged<LibraryFileWatcher>.fromOpaque(info).release()
                }
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timer?.cancel()
            self.timer = nil
            self.pending.removeAll()
            self.lock.unlock()
        }
    }

    // MARK: 事件面（事件队列线程）

    fileprivate func handleEvents(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        var relevant = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard Self.isIndexableCandidate(url) else { continue }
            pending.insert(path)
            relevant = true
        }
        guard relevant else { return }
        // 防抖计时重置（最后事件后 debounce 秒 settle；单发计时器）。
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + debounce)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let settled: [URL]
            self.lock.lock()
            settled = self.pending.map { URL(fileURLWithPath: $0) }
            self.pending.removeAll()
            self.timer = nil
            self.lock.unlock()
            // settle 时存在性过滤：变更后被删的路径不再入队（删除语义由
            // 周期全量扫描承担；watcher 只喂存活件——防抖窗内的瞬态写天然合并）。
            let alive = settled.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            guard !alive.isEmpty else { return }
            self.onSettle(alive)
        }
        timer = t
        t.resume()
    }

    /// 仅 .pdf 常规文件候选；自有存储件排除（isOwnStorageFile 复用，
    /// IndexingEngine.swift 同源过滤面）。
    static func isIndexableCandidate(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else { return false }
        return !IndexingEngine.isOwnStorageFile(url)
    }

    /// 测试直调（合成事件注入：不依赖真实 FSEvents 时序；密闭化说明
    /// internal）。走与真实回调完全相同的 handleEvents 路径。
    func testInjectEvents(_ paths: [String]) {
        queue.async { [weak self] in
            self?.handleEvents(paths)
        }
    }

    /// 测试直调：轮询等待防抖窗到期（settle 后 pending 清空即空闲）。
    func testWaitForSettle(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let idle = (timer == nil && pending.isEmpty)
            lock.unlock()
            if idle { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
#endif
