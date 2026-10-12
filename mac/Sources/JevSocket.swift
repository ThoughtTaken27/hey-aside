import Darwin
import Foundation

/// Sep 30: Jev's door, asked directly over its local socket (`<Aside account>/next/jev.sock`, mode 0600, served by Aside Phone) instead of
/// starting Node for every question. Same server, budget, cache and private-text refusal as the `jev` command; only the
/// ~100-300 ms of process start-up is gone. Any failure returns nil and the caller falls back to the command.
enum JevSocket {
    static var path: String { AsideRoot.path + "/next/jev.sock" }
    static var available: Bool { FileManager.default.fileExists(atPath: path) }

    enum Reply { case body(Data), unreachable, failed }

    /// POSTs `body` (JSON) to `route`. `.unreachable`: nothing listening (fall back); `.failed`: it connected but timed
    /// out or answered badly (don't retry elsewhere, the time is already spent).
    nonisolated static func post(_ route: String, body: Data, timeout: TimeInterval) async -> Reply {
        await withCheckedContinuation { (c: CheckedContinuation<Reply, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: postSync(route, body: body, timeout: timeout)) }
        }
    }

    private nonisolated static func postSync(_ route: String, body: Data, timeout: TimeInterval) -> Reply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let p = Array(path.utf8CString)
        guard p.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return .unreachable }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in p.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return .unreachable }

        var req = Data("POST \(route) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        req.append(body)
        let sent = req.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = send(fd, buf.baseAddress! + off, buf.count - off, 0)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard sent else { return .failed }

        var resp = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 { resp.append(contentsOf: chunk[0..<n]) } else { break }   // 0: closed (done); <0: timeout or error
            if resp.count > 4_000_000 { return .failed }
        }
        return parse(resp).map { .body($0) } ?? .failed
    }

    /// The body of an HTTP/1.1 200 response (Content-Length or chunked), nil for anything else.
    nonisolated static func parse(_ resp: Data) -> Data? {
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: resp[..<sep.lowerBound], as: UTF8.self).lowercased()
        guard head.hasPrefix("http/1.1 200") || head.hasPrefix("http/1.0 200") else { return nil }
        let body = Data(resp[sep.upperBound...])
        guard head.contains("transfer-encoding: chunked") else { return body }
        var out = Data(), i = body.startIndex
        while i < body.endIndex, let crlf = body[i...].range(of: Data("\r\n".utf8)) {
            let sizeHex = String(decoding: body[i..<crlf.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            if size == 0 { break }
            let start = crlf.upperBound, end = start + size
            guard end <= body.endIndex else { return nil }
            out.append(body[start..<end])
            i = min(end + 2, body.endIndex)
        }
        return out
    }
}
