import Foundation
import Network
import AppKit
import LiteratureCore
import LiteratureSearchUI

// MARK: - 本机只读 HTTP API（网络监听壳）
//
// 本文件是全仓唯一 import Network 宿主（DesignGuard 守卫断言固定：Sources/ 内
// 「import Network」仅此一处）。纯逻辑（token/路由/JSON 形制）在 Core 层
// LocalAPI.swift，本壳只做：环回绑定、连接收放、HTTP 报文最小解析、审计。
//
// 安全语义
// - 127.0.0.1 环回硬绑：requiredLocalEndpoint 断言固定 IPv4 环回；连接收下后
//     再验对端地址非环回即拒（两层防护）。全仓禁出现全网卡绑定字面
// （全网卡绑定反例，DesignGuard 守卫 0 命中断言固定）。
//   - fail-closed：端口占用/绑定失败 → 停服＋显式报错回设置页（lastError），
//     不做端口段扫描（单端口，冲突即回关）。
//   - 审计环形 5 条：端点（路径，不含查询串）/状态码/耗时/字节数——不含
//     查询正文、不含访问凭据（日志纪律同款）。
//   - 服务生命周期随设置页开关启停；默认关；无 LaunchAgent、无守护进程、
//     无后台自动启动。App 退出（willTerminate）自动停服。
//   - 零写动词：一切分派经 Core 路由（只注册 GET，其余动词 405——结构保证）。

/// 审计条目（环形缓冲，最多 5 条；设置页陈列）。
struct LocalAPIAuditEntry: Identifiable, Equatable {
    let id = UUID()
    /// 请求路径（不含查询串——查询正文不落审计）。
    let endpoint: String
    let status: Int
    let milliseconds: Double
    let bytes: Int
    let at: Date
}

/// 监听壳。ObservableObject：设置页直接观察 running/lastError/audit。
/// 全部可变状态只在主队列变更（Network 回调一律 dispatch 到主队列）。
final class LocalAPIServer: ObservableObject {
    /// 监听端口（常数集中一处；docs/LOCAL-API.md 规格件同值登记）。
    static let defaultPort: UInt16 = 47115
    /// 审计环形容量。
    static let auditCapacity = 5
    /// 请求报文读取上限（字节）：超限直接掐线——环回面 DoS 防护之一。
    static let maxRequestBytes = 64 * 1024
    /// 功能扩展：连接空闲时限（秒）——客户端连上后不
    /// 把头发完（\r\n\r\n 不出现）超过此时限即掐线，防半开请求挂住收发
    /// 串行队列。每次收到数据（含部分头）即推迟。
    static let idleTimeout: TimeInterval = 15

    /// 当前访问凭据（每次 App 启动重新生成；设置页一键复制）。
    let token: String

    @Published private(set) var running = false
    /// fail-closed 报错（绑定失败/端口占用等；nil = 无错）。显式呈现，不静默。
    @Published private(set) var lastError: String?
    @Published private(set) var audit: [LocalAPIAuditEntry] = []

    private var listener: NWListener?
    /// 连接收发串行队列（网络 I/O 与报文解析；路由后状态变更一律回主队列）。
    private let queue = DispatchQueue(label: "literaturesearch.localapi", qos: .utility)
    private var terminateObserver: NSObjectProtocol?

    init(token: String = LocalAPIToken.generate()) {
        self.token = token
    }

    // MARK: 启停

    /// 启动监听（主线程调用）。store/search/highlights 由调用方在主线程解析
    /// 好句柄传入（AppState lazy store 同款纪律——不在网络队列上触发任何
    /// lazy 初始化）。
    func start(store: IndexStore, search: SearchService, highlights: HighlightStore,
               port: UInt16 = LocalAPIServer.defaultPort) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running else { return }
        stopListener()   // 残留监听先清（重复 start 幂等）
        let router = LocalAPIRouter(token: token,
                                    appVersion: Self.appVersion,
                                    schemaVersion: IndexStore.currentSchemaVersion,
                                    providers: .makeLive(store: store, search: search,
                                                         highlights: highlights))
        // router 不再落实例属性——主线程 start
        // 写、网络队列 route 读的跨队列共享可变属性是数据竞争面。改为本闭包
        // 捕获局部值随连接传参：start 的 happens-before 经监听器启动建立，
        // 重启即换新 router，旧连接持有旧值自然收敛，零锁零竞争。
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 环回硬绑：requiredLocalEndpoint 把监听端断言固定在 127.0.0.1（第一层
        // 防护；第二层=连接收下后再验对端地址）。
        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            failClosed(L10n.localAPIInvalidPort)
            return
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: endpoint)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            failClosed("\(L10n.localAPIStartFailedPrefix)\(error)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            // Network 回调线程 → 主队列变更可观察状态。
            DispatchQueue.main.async {
                self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.accept(connection, router: router)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        // App 退出自动停服（TTSSpeaker willTerminate 同款惯例）。
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.stop()
            }
    }

    /// 停止监听（主线程调用；幂等）。主动关停同时清 fail-closed 报错残留——
    /// 失败当时已显式呈现过，关停后状态行回「已停止」不陈列旧错。
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopListener()
        running = false
        lastError = nil
    }

    private func stopListener() {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        listener?.cancel()
        listener = nil
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            running = true
            lastError = nil
        case .failed(let error):
            // fail-closed：绑定/监听失败 → 停服＋显式报错（不扫端口段）。
            failClosed("\(L10n.localAPIStartFailedPrefix)\(error)")
        case .cancelled:
            running = false
        default:
            break
        }
    }

    private func failClosed(_ message: String) {
        failStart(message)
    }

    /// fail-closed 显式失败（绑定失败/数据面未就绪共用）：停服＋错误面呈现。
    /// internal：AppState 在索引库未就绪时也走此口（错误回设置页，不静默）。
    func failStart(_ message: String) {
        stopListener()
        running = false
        lastError = message
    }

    // MARK: 连接收放

    /// 每连接上下文：connection+router+空闲计时器一体随闭包捕获——
    /// 收发本就同串行队列（queue），计时器回调投递到同一队列，无新竞争面。
    private final class ConnectionContext {
        let connection: NWConnection
        let router: LocalAPIRouter
        let idleTimer: LocalAPIIdleTimer

        init(connection: NWConnection, router: LocalAPIRouter, idleTimer: LocalAPIIdleTimer) {
            self.connection = connection
            self.router = router
            self.idleTimer = idleTimer
        }
    }

    private func accept(_ connection: NWConnection, router: LocalAPIRouter) {
        guard case let .hostPort(host, _) = connection.endpoint, Self.isLoopback(host) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        // 空闲计时：accept 即武装空闲计时；onFire 掐线（无请求内容无凭据，照
        // logReadFailure 先例只留一行 stderr）。readRequest 每收到数据
        // （含部分头）reset；头收齐派发路由前 cancel。
        let context = ConnectionContext(
            connection: connection, router: router,
            idleTimer: LocalAPIIdleTimer(interval: Self.idleTimeout, queue: queue, onFire: {
                Self.logIdleDrop()
                connection.cancel()
            }))
        connection.start(queue: queue)
        context.idleTimer.reset()
        readRequest(context, buffer: Data())
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        if case .ipv4(let address) = host {
            return address == .loopback
        }
        return false
    }

    /// 报文读取：累积到头部结束（空行）即解析派发；超限掐线；空闲超限掐线。
    private func readRequest(_ context: ConnectionContext, buffer: Data) {
        let connection = context.connection
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let error {
                context.idleTimer.cancel()
                Self.logReadFailure(error)
                connection.cancel()
                return
            }
            if let data {
                buffer.append(data)
                // 空闲计时：任何到达数据（含部分头）都推迟空闲计时。
                context.idleTimer.reset()
            }
            if buffer.count > Self.maxRequestBytes {
                context.idleTimer.cancel()
                connection.cancel()
                return
            }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    context.idleTimer.cancel()
                    connection.cancel()
                    return
                }
                self.readRequest(context, buffer: buffer)
                return
            }
            context.idleTimer.cancel()
            let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let response = self.route(head: head, router: context.router)
            self.send(response, over: connection)
        }
    }

    /// HTTP 头解析 → Core 路由（本壳零业务语义）。耗时/字节审计在此结算。
    /// router 随连接传参（连接上下文：不落实例属性，见 start 内注记）。
    private func route(head: String, router: LocalAPIRouter) -> LocalAPIResponse {
        let started = Date()
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return .error(400, "malformed request")
        }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .error(400, "malformed request line")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        var authorization: String?
        for line in lines {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" {
                authorization = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let response = router.route(method: method, target: target, authorization: authorization)
        recordAudit(endpoint: Self.endpointName(of: target),
                    status: response.status,
                    milliseconds: Date().timeIntervalSince(started) * 1000,
                    bytes: response.body.count)
        return response
    }

    /// 审计端点名：只留路径（查询串不进审计——约束：query 正文不落日志）。
    private static func endpointName(of target: String) -> String {
        guard let questionMark = target.firstIndex(of: "?") else { return target }
        return String(target[target.startIndex..<questionMark])
    }

    private func recordAudit(endpoint: String, status: Int, milliseconds: Double, bytes: Int) {
        let entry = LocalAPIAuditEntry(endpoint: endpoint, status: status,
                                       milliseconds: milliseconds, bytes: bytes, at: Date())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audit.append(entry)
            if self.audit.count > Self.auditCapacity {
                self.audit.removeFirst(self.audit.count - Self.auditCapacity)
            }
        }
    }

    /// 应答发送（Connection: close——无 keep-alive 会话态，一请求一连接）。
    private func send(_ response: LocalAPIResponse, over connection: NWConnection) {
        let reason = Self.reasonPhrase(response.status)
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    /// /ping 的 version 字段（App 包短版本；CLI/测试环境取不到如实落 "dev"）。
    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    /// 读取失败向 stderr 记录（一行：错误描述，不含请求内容不含凭据；
    /// 不进审计环形——网络层杂音与业务审计分离）。
    private static func logReadFailure(_ error: NWError) {
        FileHandle.standardError.write(Data("localapi: connection read failed: \(error)\n".utf8))
    }

    /// 空闲掐线向 stderr 记录（一行；无请求内容无凭据，logReadFailure
    /// 同款基准）。
    private static func logIdleDrop() {
        FileHandle.standardError.write(Data("localapi: idle connection dropped\n".utf8))
    }
}
