import Foundation
import Network

/// 本地 HTTP 服务：
///   * 命中资源包的文件直接从包内读出（支持 Range，不占内存）
///   * 其余请求（门户页面、/auth/*、/diag、WebSocket /ws）原样转发到真实服务器
/// 这样 WebView 里始终是「同一个源」，登录 Cookie 和战斗连接都不用改。
final class LocalHTTPServer {
    static let shared = LocalHTTPServer()

    static let upstreamHost = "118.89.182.49"
    static let upstreamPort: UInt16 = 81

    private let listenerQueue = DispatchQueue(label: "zxr.http.listener")
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]

    private(set) var port: UInt16 = 0

    func start(preferred: UInt16 = 18901, completion: @escaping (Result<UInt16, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var candidate = preferred
            var lastError: Error = NSError(domain: "zxr.http", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "无法绑定本地端口"])
            for _ in 0..<40 {
                guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { break }
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                do {
                    let listener = try NWListener(using: parameters, on: nwPort)
                    let ready = DispatchSemaphore(value: 0)
                    var bound = false
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            bound = true
                            ready.signal()
                        case .failed(let error):
                            lastError = error
                            ready.signal()
                        case .cancelled:
                            ready.signal()
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self else { return }
                        let handler = HTTPConnection(connection: connection)
                        let id = handler.id
                        self.connections[id] = handler
                        handler.onClose = { [weak self] in
                            self?.connections.removeValue(forKey: id)
                        }
                        handler.start()
                    }
                    listener.start(queue: self.listenerQueue)
                    ready.wait()
                    if bound {
                        self.listener = listener
                        self.port = candidate
                        NSLog("[ZXR] 本地服务已启动 127.0.0.1:\(candidate)")
                        DispatchQueue.main.async { completion(.success(candidate)) }
                        return
                    }
                    listener.cancel()
                } catch {
                    lastError = error
                }
                candidate += 1
            }
            DispatchQueue.main.async { completion(.failure(lastError)) }
        }
    }
}

// MARK: - 单连接处理

final class HTTPConnection {
    struct Request {
        var method: String
        var target: String
        var version: String
        var headers: [String: String]
        var rawHead: Data
        var body: Data

        var path: String {
            guard let mark = target.firstIndex(of: "?") else { return target }
            return String(target[target.startIndex..<mark])
        }

        var query: String? {
            guard let mark = target.firstIndex(of: "?") else { return nil }
            let value = String(target[target.index(after: mark)...])
            return value.isEmpty ? nil : value
        }
    }

    let id = UUID()
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var buffer = Data()
    private var request: Request?
    private var isClosed = false
    private var isUpgraded = false

    private static let headerLimit = 128 * 1024
    private static let chunkSize = 1 << 20

    init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "zxr.http.conn.\(UUID().uuidString)")
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pump()
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: 读取与解析

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("[ZXR] 客户端读取失败：\(error)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if isComplete && self.buffer.isEmpty {
                self.close()
                return
            }
            self.pump()
        }
    }

    private func pump() {
        if request == nil {
            guard let headRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.headerLimit { close(); return }
                receiveMore()
                return
            }
            let headData = buffer[buffer.startIndex..<headRange.lowerBound]
            guard let parsed = parse(head: Data(headData)) else {
                respondPlain(status: 400, body: "Bad Request")
                return
            }
            request = parsed
            buffer.removeSubrange(buffer.startIndex..<headRange.upperBound)

            if parsed.headers["upgrade"]?.lowercased() == "websocket" {
                startUpgrade(request: parsed, leftover: buffer)
                return
            }
        }

        guard let current = request else { return }
        let expected = Int(current.headers["content-length"] ?? "0") ?? 0
        if buffer.count < expected {
            receiveMore()
            return
        }
        var complete = current
        if expected > 0 {
            complete.body = Data(buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: expected)])
        }
        buffer.removeAll(keepingCapacity: false)
        request = complete
        handle(complete)
    }

    private func parse(head: Data) -> Request? {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] == nil {
                headers[name] = value
            }
        }
        return Request(method: String(parts[0]).uppercased(),
                       target: String(parts[1]),
                       version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1",
                       headers: headers,
                       rawHead: head,
                       body: Data())
    }

    // MARK: 路由

    private func handle(_ request: Request) {
        let decodedPath = request.path.removingPercentEncoding ?? request.path
        if request.method == "GET" || request.method == "HEAD",
           let entry = PackStore.shared.entry(for: decodedPath) {
            servePack(request: request, path: decodedPath, entry: entry)
            return
        }
        proxy(request: request)
    }

    private func servePack(request: Request, path: String, entry: PackEntry) {
        var status = 200
        var offset: Int64 = 0
        var length = entry.size
        var extraHeaders: [String] = []

        if let rangeHeader = request.headers["range"],
           let ranged = Self.parseRange(rangeHeader, size: entry.size) {
            status = 206
            offset = ranged.0
            length = ranged.1
            extraHeaders.append("Content-Range: bytes \(offset)-\(offset + Int64(length) - 1)/\(entry.size)")
        }

        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(entry.mime)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for line in extraHeaders { head += line + "\r\n" }
        head += "\r\n"

        let headData = Data(head.utf8)
        if request.method == "HEAD" || length == 0 {
            send(data: headData) { [weak self] _ in self?.close() }
            return
        }
        send(data: headData) { [weak self] ok in
            guard let self, ok else { self?.close(); return }
            self.sendPackBody(path: path, offset: offset, remaining: length)
        }
    }

    private func sendPackBody(path: String, offset: Int64, remaining: Int) {
        if remaining <= 0 { close(); return }
        let count = min(remaining, Self.chunkSize)
        guard let chunk = PackStore.shared.read(path: path, offset: offset, length: count), !chunk.isEmpty else {
            close()
            return
        }
        send(data: chunk) { [weak self] ok in
            guard let self, ok else { self?.close(); return }
            self.sendPackBody(path: path, offset: offset + Int64(chunk.count), remaining: remaining - chunk.count)
        }
    }

    private static func parseRange(_ header: String, size: Int) -> (Int64, Int)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            let length = min(suffix, size)
            return (Int64(size - length), length)
        }
        guard let start = Int(parts[0]), start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : min(Int(parts[1]) ?? (size - 1), size - 1)
        guard end >= start else { return nil }
        return (Int64(start), end - start + 1)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }

    // MARK: 反向代理

    private static let skippedRequestHeaders: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding",
        "content-length", "accept-encoding", "upgrade", "te", "trailer"
    ]

    private static let skippedResponseHeaders: Set<String> = [
        "connection", "keep-alive", "transfer-encoding", "content-length",
        "content-encoding", "proxy-authenticate", "proxy-authorization", "te", "trailer", "upgrade"
    ]

    private static let proxyDelegate = NoRedirectDelegate()
    private static let proxySession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        // 资源缺失时会回落到线上，放宽单域名并发，避免排队拖慢首屏
        config.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: config, delegate: proxyDelegate, delegateQueue: nil)
    }()

    private func proxy(request: Request) {
        guard var components = URLComponents(string: "http://\(LocalHTTPServer.upstreamHost):\(LocalHTTPServer.upstreamPort)") else {
            respondPlain(status: 502, body: "Bad upstream")
            return
        }
        components.percentEncodedPath = request.path
        components.percentEncodedQuery = request.query
        guard let url = components.url else {
            respondPlain(status: 400, body: "Bad path")
            return
        }
        var outgoing = URLRequest(url: url)
        outgoing.httpMethod = request.method
        if !request.body.isEmpty, request.method != "GET", request.method != "HEAD" {
            outgoing.httpBody = request.body
        }
        for (name, value) in request.headers where !Self.skippedRequestHeaders.contains(name) {
            outgoing.setValue(value, forHTTPHeaderField: name)
        }
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let task = Self.proxySession.dataTask(with: outgoing) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                NSLog("[ZXR] 代理失败 \(request.target)：\(error.localizedDescription)")
                self.respondPlain(status: 502, body: "Upstream unavailable: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.respondPlain(status: 502, body: "Bad upstream response")
                return
            }
            let body = data ?? Data()
            var head = "HTTP/1.1 \(http.statusCode) \(Self.reason(http.statusCode))\r\n"
            for (name, value) in http.allHeaderFields {
                let key = String(describing: name)
                if Self.skippedResponseHeaders.contains(key.lowercased()) { continue }
                head += "\(key): \(value)\r\n"
            }
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"

            var payload = Data(head.utf8)
            if request.method != "HEAD" { payload.append(body) }
            self.send(data: payload) { [weak self] _ in self?.close() }
        }
        task.resume()
    }

    private func respondPlain(status: Int, body: String) {
        let data = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(data)
        send(data: payload) { [weak self] _ in self?.close() }
    }

    // MARK: WebSocket 透传

    private func startUpgrade(request: Request, leftover: Data) {
        isUpgraded = true
        guard let nwPort = NWEndpoint.Port(rawValue: LocalHTTPServer.upstreamPort) else {
            close()
            return
        }
        let up = NWConnection(host: NWEndpoint.Host(LocalHTTPServer.upstreamHost), port: nwPort, using: .tcp)
        upstream = up
        let head = rewriteHost(request: request)
        up.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var payload = head
                payload.append(leftover)
                up.send(content: payload, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil {
                        self.close()
                        return
                    }
                    self.pipeUpstreamToClient(up)
                    self.pipeClientToUpstream(up)
                })
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    private func rewriteHost(request: Request) -> Data {
        let text = String(decoding: request.rawHead, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return request.rawHead }
        var rebuilt = [first, "Host: \(LocalHTTPServer.upstreamHost):\(LocalHTTPServer.upstreamPort)"]
        for line in lines.dropFirst() where !line.isEmpty {
            if line.lowercased().hasPrefix("host:") { continue }
            rebuilt.append(line)
        }
        lines = rebuilt
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func pipeUpstreamToClient(_ up: NWConnection) {
        up.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil || isComplete {
                up.cancel()
                self.close()
                return
            }
            self.pipeUpstreamToClient(up)
        }
    }

    private func pipeClientToUpstream(_ up: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                up.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil || isComplete {
                up.cancel()
                self.close()
                return
            }
            self.pipeClientToUpstream(up)
        }
    }

    // MARK: 发送

    private func send(data: Data, completion: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        upstream?.cancel()
        upstream = nil
        connection.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 3xx 原样交给 WebView，登录流程依赖它自己跳转。
        completionHandler(nil)
    }
}
