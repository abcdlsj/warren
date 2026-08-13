import Darwin
import Foundation

// `warren` CLI: talks to the running app's WebSocket relay so scripts and
// agents can create sessions, send input, and read replies headlessly.

let arguments = Array(CommandLine.arguments.dropFirst())

struct WarrenCLIError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func readToken() -> String {
    let defaults = UserDefaults(suiteName: "com.abcdlsj.warren")
    if let token = defaults?.string(forKey: "webRelay.token"), !token.isEmpty {
        return token
    }
    fail("Missing webRelay.token; start Warren.app first.")
}

final class RelayClient {
    let fd: Int32
    var buffer = Data()

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WarrenCLIError(description: "socket failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8788).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw WarrenCLIError(description: "connect failed; is Warren.app running?") }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request =
            "GET /ws HTTP/1.1\r\n" +
            "Host: 127.0.0.1:8788\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        try? Data(request.utf8).write(to: URL(fileURLWithPath: "/tmp/warren-cli-request.bin"))
        _ = request.withCString { write(fd, $0, strlen($0)) }
        try readAvailable(timeout: 5)
        guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil,
              let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            throw WarrenCLIError(description: "bad websocket handshake")
        }
        let header = String(data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound), encoding: .utf8) ?? ""
        guard header.contains("101 Switching Protocols") else {
            throw WarrenCLIError(description: header)
        }
        buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
    }

    deinit {
        Darwin.close(fd)
    }

    func sendText(_ text: String) throws {
        try sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func sendBinary(_ data: Data) throws {
        try sendFrame(opcode: 0x2, payload: data)
    }

    func readFrame(timeout: TimeInterval) throws -> (opcode: UInt8, payload: Data) {
        while true {
            if let frame = Self.parseFrame(from: &buffer) {
                return frame
            }
            try readAvailable(timeout: timeout)
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data) throws {
        var header = Data()
        header.append(0x80 | opcode)
        if payload.count < 126 {
            header.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            header.append(0x80 | 126)
            header.append(contentsOf: withUnsafeBytes(of: UInt16(payload.count).bigEndian) { Array($0) })
        } else {
            header.append(0x80 | 127)
            header.append(contentsOf: withUnsafeBytes(of: UInt64(payload.count).bigEndian) { Array($0) })
        }
        let mask = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        header.append(mask)
        var masked = Data()
        for (index, byte) in payload.enumerated() {
            masked.append(byte ^ mask[index % 4])
        }
        var offset = 0
        let data = header + masked
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress?.advanced(by: offset), data.count - offset)
            }
            if written <= 0 { throw WarrenCLIError(description: "write failed") }
            offset += written
        }
    }

    private func readAvailable(timeout: TimeInterval) throws {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, Int32(timeout * 1000))
        guard ready > 0 else { throw WarrenCLIError(description: "timeout") }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { throw WarrenCLIError(description: "connection closed") }
        buffer.append(Data(chunk[0..<count]))
    }

    private static func parseFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            length = Int(buffer[buffer.startIndex + offset]) << 8
                | Int(buffer[buffer.startIndex + offset + 1])
            offset += 2
        } else if length == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(buffer[buffer.startIndex + offset + i])
            }
            length = Int(value)
            offset += 8
        }
        var mask: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            mask = Array(buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + 4)))
            offset += 4
        }
        guard buffer.count >= offset + length else { return nil }
        var payload = Data(buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + length)))
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }
        buffer.removeFirst(offset + length)
        return (opcode, payload)
    }
}

func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

func authRoster() throws -> (RelayClient, [String: Any]) {
    let client = try RelayClient()
    try client.sendText(json(["t": "auth", "token": readToken()]))
    let (_, payload) = try client.readFrame(timeout: 5)
    guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          object["t"] as? String == "roster" else {
        throw WarrenCLIError(description: "auth failed")
    }
    return (client, object)
}

func run() throws {
    guard let command = arguments.first else {
        print("usage: warren session list | agent create session <title> | session send <id> <text> | session read <id> [--timeout N] [--contains TEXT]")
        return
    }

    if command == "session", arguments.dropFirst().first == "list" {
        let (_, roster) = try authRoster()
        let sessions = roster["sessions"] as? [[String: Any]] ?? []
        for session in sessions {
            print("\(session["id"] ?? "") \(session["title"] ?? "") \(session["kind"] ?? "")")
        }
        return
    }

    if command == "agent", arguments.dropFirst().first == "create", arguments.dropFirst().dropFirst().first == "session" {
        var rest = Array(arguments.dropFirst(3))
        var title = "Agent"
        var command = "codex"
        var kind = "codex"
        var workspaceID: String?
        if let first = rest.first, !first.hasPrefix("--") {
            title = first
            rest.removeFirst()
        }
        var index = 0
        while index < rest.count {
            if rest[index] == "--command", index + 1 < rest.count {
                command = rest[index + 1]
                index += 2
            } else if rest[index] == "--kind", index + 1 < rest.count {
                kind = rest[index + 1]
                index += 2
            } else if rest[index] == "--workspace", index + 1 < rest.count {
                workspaceID = rest[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        let (client, roster) = try authRoster()
        let workspaces = roster["workspaces"] as? [[String: Any]] ?? []
        let resolvedWorkspaceID: String
        if let workspaceID {
            resolvedWorkspaceID = workspaceID
        } else if let workspace = workspaces.first, let id = workspace["id"] as? String {
            resolvedWorkspaceID = id
        } else {
            throw WarrenCLIError(description: "no workspace available")
        }
        try client.sendText(json([
            "t": "create",
            "workspace": resolvedWorkspaceID,
            "command": command,
            "kind": kind,
            "title": title,
        ]))
        let (_, payload) = try client.readFrame(timeout: 15)
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        if let session = object?["session"] as? String, !session.isEmpty {
            print(session)
        } else {
            print(object?["message"] ?? "create failed")
        }
        return
    }

    if command == "session", arguments.dropFirst().first == "send" {
        let parts = Array(arguments.dropFirst(2))
        guard parts.count >= 2 else { throw WarrenCLIError(description: "usage: warren session send <id> <text>") }
        let sessionID = parts[0]
        let text = parts.dropFirst().joined(separator: " ")
        let payload = (text.hasSuffix("\n") || text.hasSuffix("\r")) ? text : text + "\r"
        let (client, _) = try authRoster()
        try client.sendText(json(["t": "attach", "session": sessionID]))
        _ = try client.readFrame(timeout: 5)
        try client.sendText(json(["t": "input", "data": Data(payload.utf8).base64EncodedString()]))
        print("sent")
        return
    }

    if command == "session", arguments.dropFirst().first == "read" {
        let parts = Array(arguments.dropFirst(2))
        guard let sessionID = parts.first else { throw WarrenCLIError(description: "usage: warren session read <id>") }
        var timeout: TimeInterval = 8
        var needle: String?
        var index = 1
        while index < parts.count {
            if parts[index] == "--timeout", index + 1 < parts.count {
                timeout = Double(parts[index + 1]) ?? 8
                index += 2
            } else if parts[index] == "--contains", index + 1 < parts.count {
                needle = parts[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        let (client, _) = try authRoster()
        try client.sendText(json(["t": "attach", "session": sessionID]))
        _ = try client.readFrame(timeout: 5)
        var output = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                let (_, payload) = try client.readFrame(timeout: max(0.1, deadline.timeIntervalSinceNow))
                output += String(decoding: payload, as: UTF8.self)
                if let needle, output.contains(needle) {
                    print(output)
                    return
                }
            } catch {
                if Date() >= deadline { break }
            }
        }
        print(output)
        if let needle, !output.contains(needle) {
            throw WarrenCLIError(description: "expected text not found: \(needle)")
        }
        return
    }

    throw WarrenCLIError(description: "unknown command: \(command)")
}

do {
    try run()
} catch {
    fail(String(describing: error))
}
