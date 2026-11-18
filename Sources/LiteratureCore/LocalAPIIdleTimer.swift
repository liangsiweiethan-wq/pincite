import Foundation
import Dispatch

// MARK: - 空闲计时器
//
// 防半开请求挂住串行队列：客户端连上后不把头发完（\r\n\r\n 不出现），旧
// readRequest 递归 receive 无任何超时——连接与 buffer 常驻。本组件把「空闲
// 掐线」计时抽成可单测的纯 Dispatch 封装：注入 interval/queue/onFire，
// reset 推迟、cancel 停火；壳层（LocalAPIServer）只组装，单元测试不
// 依赖真 socket（0.1s 短间隔断言「到时 fire／reset 推迟／cancel 停火」）。
//
// 形态：一次性 DispatchSourceTimer——每次 reset 重建 source（取消的 source
// 不可复用）；fire 后自灭，不重复触发。全部状态变更持 NSLock，回调投递到
// 注入队列（与收发同队即天然串行）。

public final class LocalAPIIdleTimer {
    /// 空闲时限（秒）：自最近一次 reset 起算，到点即 onFire。
    public let interval: TimeInterval
    /// 回调投递队列（壳层传收发串行队列——fire 与 I/O 同队序列化）。
    private let queue: DispatchQueue
    private let onFire: () -> Void

    private let stateLock = NSLock()
    private var source: DispatchSourceTimer?

    public init(interval: TimeInterval, queue: DispatchQueue, onFire: @escaping () -> Void) {
        self.interval = interval
        self.queue = queue
        self.onFire = onFire
    }

    deinit {
        cancel()
    }

    /// 武装/推迟计时：取消在途 source，重建一个 now+interval 的一次性
    /// source。收到任何数据（含部分头）都应调用。
    public func reset() {
        stateLock.lock()
        source?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // 一次性语义：fire 即拆（防持有已废 source）。
            self.stateLock.lock()
            if self.source === timer { self.source = nil }
            self.stateLock.unlock()
            self.onFire()
        }
        timer.resume()
        source = timer
        stateLock.unlock()
    }

    /// 停火（头收齐派发路由后／连接已关闭等场景）。已 fire 或未武装时无害。
    public func cancel() {
        stateLock.lock()
        source?.cancel()
        source = nil
        stateLock.unlock()
    }
}
