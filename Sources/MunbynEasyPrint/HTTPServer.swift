import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    /// Lower-cased header names.
    var headers: [String: String]
    var body: [UInt8]
}

struct HTTPResponse {
    var status = 200
    var reason = "OK"
    var contentType = "application/ipp"
    var body: [UInt8] = []

    static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, reason: "Not Found", contentType: "text/plain", body: Array("Not found\n".utf8))
    }
}

/// Minimal HTTP/1.1 server for IPP: keep-alive, `Expect: 100-continue` and
/// chunked request bodies (CUPS streams documents chunked). Loopback only.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "MunbynEasyPrint.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start(onState: @escaping @Sendable (NWListener.State) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let c = HTTPConnection(connection: conn, queue: self.queue, handler: self.handler)
            let key = ObjectIdentifier(c)
            self.connections[key] = c
            c.onClose = { [weak self] in self?.connections[key] = nil }
            c.start()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private var buffer: [UInt8] = []
    private var sentContinue = false
    private var closed = false
    var onClose: (() -> Void)?

    private static let crlf: [UInt8] = [13, 10]
    private static let headerEnd: [UInt8] = [13, 10, 13, 10]

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buffer.append(contentsOf: data) }
            self.process()
            if isComplete || error != nil { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    private func process() {
        while !closed {
            guard let headEnd = Self.find(Self.headerEnd, in: buffer, from: 0) else { return }
            let headText = String(decoding: buffer[0..<headEnd], as: UTF8.self)
            var lines = headText.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else { respond(HTTPResponse(status: 400, reason: "Bad Request", contentType: "text/plain"), close: true); return }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }

            let bodyStart = headEnd + 4
            let body: [UInt8]
            let consumed: Int
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                guard let (decoded, end) = Self.decodeChunked(buffer, from: bodyStart) else { sendContinueIfNeeded(headers); return }
                body = decoded
                consumed = end
            } else {
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard buffer.count - bodyStart >= length else { sendContinueIfNeeded(headers); return }
                body = Array(buffer[bodyStart..<(bodyStart + length)])
                consumed = bodyStart + length
            }

            buffer.removeFirst(consumed)
            sentContinue = false
            let request = HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
            let response = handler(request)
            respond(response, close: headers["connection"]?.lowercased() == "close")
        }
    }

    private func sendContinueIfNeeded(_ headers: [String: String]) {
        guard !sentContinue, headers["expect"]?.lowercased() == "100-continue" else { return }
        sentContinue = true
        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
    }

    private func respond(_ r: HTTPResponse, close shouldClose: Bool) {
        var head = "HTTP/1.1 \(r.status) \(r.reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\n"
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Server: MunbynEasyPrint/1.0 IPP/2.0\r\n"
        head += shouldClose ? "Connection: close\r\n\r\n" : "Connection: Keep-Alive\r\n\r\n"
        var out = Data(head.utf8)
        out.append(contentsOf: r.body)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            if shouldClose { self?.close() }
        })
    }

    /// Returns the de-chunked body and the index just past the message, or nil if incomplete.
    private static func decodeChunked(_ buf: [UInt8], from start: Int) -> ([UInt8], Int)? {
        var body: [UInt8] = []
        var pos = start
        while true {
            guard let lineEnd = find(crlf, in: buf, from: pos) else { return nil }
            let sizeText = String(decoding: buf[pos..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            pos = lineEnd + 2
            if size == 0 {
                // Skip optional trailers up to the blank line.
                while true {
                    guard let end = find(crlf, in: buf, from: pos) else { return nil }
                    let blank = end == pos
                    pos = end + 2
                    if blank { return (body, pos) }
                }
            }
            guard buf.count >= pos + size + 2 else { return nil }
            body.append(contentsOf: buf[pos..<(pos + size)])
            pos += size + 2
        }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where hay[i + j] != needle[j] { match = false; break }
                if match { return i }
            }
            i += 1
        }
        return nil
    }
}
