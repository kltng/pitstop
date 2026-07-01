import Foundation
import Darwin

/// One-shot loopback HTTP server on a raw BSD socket, bound to `127.0.0.1`.
/// Captures the first `GET …?code=…&state=…`, replies 200, yields it.
///
/// Raw sockets (not Network.framework) because `NWListener` fails to bind in
/// some environments, and a short-lived localhost OAuth callback needs exactly
/// this and nothing more.
final class LoopbackServer {
    struct Captured { let code: String; let state: String }
    struct ServerError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0

    /// Parse an HTTP request line's query. Pure.
    static func parse(requestLine: String) -> Captured? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let query = parts[1].split(separator: "?").dropFirst().first else { return nil }
        return captured(fromQuery: String(query))
    }

    /// Parse a value the user pasted from claude.ai's callback page. Accepts a
    /// full redirect URL, a "CODE#STATE" string, or a "code=…&state=…" query.
    static func parsePasted(_ input: String) -> Captured? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let comps = URLComponents(string: s), comps.scheme != nil,
           let cap = captured(fromItems: comps.queryItems) { return cap }
        if s.contains("#") {
            let hs = s.split(separator: "#", maxSplits: 1)
            if hs.count == 2 { return Captured(code: String(hs[0]), state: String(hs[1])) }
        }
        return captured(fromQuery: s)
    }

    private static func captured(fromQuery query: String) -> Captured? {
        var code: String?, state: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let v = kv[1].removingPercentEncoding ?? String(kv[1])
            if kv[0] == "code" { code = v } else if kv[0] == "state" { state = v }
        }
        guard let code, let state else { return nil }
        return Captured(code: code, state: state)
    }

    private static func captured(fromItems items: [URLQueryItem]?) -> Captured? {
        guard let items else { return nil }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else { return nil }
        return Captured(code: code, state: state)
    }

    /// Bind the first available loopback port in `ports`.
    func start(ports: [UInt16]) throws {
        for p in ports {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = p.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0, listen(s, 1) == 0 { fd = s; port = p; return }
            close(s)
        }
        throw ServerError(msg: "No free loopback port in \(ports)")
    }

    /// Await the first callback (blocking accept on a background queue), racing a
    /// timeout. `stop()` unblocks a pending accept so the task can be cancelled.
    func waitForCallback(timeout: TimeInterval) async throws -> Captured {
        let listenFD = fd
        guard listenFD >= 0 else { throw ServerError(msg: "Loopback server not started") }
        return try await withThrowingTaskGroup(of: Captured.self) { group in
            group.addTask { try await self.acceptOne(listenFD) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ServerError(msg: "Timed out waiting for the browser")
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    private func acceptOne(_ listenFD: Int32) async throws -> Captured {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let client = accept(listenFD, nil, nil)
                guard client >= 0 else {
                    cont.resume(throwing: ServerError(msg: "accept failed (errno \(errno))")); return
                }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(client, &buf, buf.count)
                let text = n > 0 ? (String(bytes: buf[0..<n], encoding: .utf8) ?? "") : ""
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                let body = "You can close this tab and return to PitStop."
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = resp.withCString { write(client, $0, strlen($0)) }
                close(client)
                if let cap = LoopbackServer.parse(requestLine: firstLine) {
                    cont.resume(returning: cap)
                } else {
                    cont.resume(throwing: ServerError(msg: "Unparseable callback"))
                }
            }
        }
    }

    func stop() {
        if fd >= 0 { close(fd); fd = -1 }
    }
}
