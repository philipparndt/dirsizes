import Foundation
import Network

/// Minimal MCP server (Streamable HTTP, JSON responses only) on a loopback port.
///
/// HTTP rather than stdio because the app is already running and the client has to call into
/// it; `dirsizes mcp` bridges stdio-only clients to this. Every request needs the bearer token,
/// since loopback alone lets any local process connect.
final class MCPServer: @unchecked Sendable {
    struct Tool {
        let name: String
        let description: String
        /// JSON Schema for the arguments, sent verbatim in `tools/list`.
        let inputSchema: [String: Any]
        /// Read-only tools are marked as such, so clients can run them without asking.
        let readOnly: Bool
        /// Returns the text sent back to the client. Thrown errors become `isError` results.
        let handler: @MainActor ([String: Any]) async throws -> String
    }

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    let token: String
    private(set) var port: UInt16 = 0

    private let name: String
    private let version: String
    private let instructions: String
    private var tools: [String: Tool] = [:]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dirsizes.mcp", qos: .userInitiated)

    init(name: String, version: String, instructions: String, token: String = UUID().uuidString) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.token = token
    }

    func register(_ tool: Tool) {
        tools[tool.name] = tool
    }

    /// Starts listening on a free loopback port and returns it once the listener is ready.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Loopback only: this server must never be reachable from other machines.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            // Only touched on `queue`, which is serial.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let port = listener.port?.rawValue ?? 0
                    self?.port = port
                    continuation.resume(returning: port)
                case let .failed(error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Requests can arrive split across reads, and keep-alive connections send several, so the
    /// buffer is carried between reads and drained one request at a time.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
                while let (request, consumed) = HTTPRequest.parse(buffer) {
                    buffer.removeFirst(consumed)
                    self.serve(request, on: connection)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func serve(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.method == "POST" else {
            // No server-initiated messages, so no SSE stream to GET.
            send(status: "405 Method Not Allowed", body: Data(), on: connection)
            return
        }
        guard request.header("authorization") == "Bearer \(token)" else {
            send(status: "401 Unauthorized", body: Data(), on: connection)
            return
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            send(jsonRPCError: -32700, message: "Parse error", id: nil, on: connection)
            return
        }
        // Notifications have no id and get no response body.
        guard let id = message["id"] else {
            send(status: "202 Accepted", body: Data(), on: connection)
            return
        }

        let method = message["method"] as? String ?? ""
        let parameters = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            respond(result: [
                "protocolVersion": parameters["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
                "instructions": instructions,
            ], id: id, on: connection)

        case "ping":
            respond(result: [:], id: id, on: connection)

        case "tools/list":
            let listed = tools.values.sorted { $0.name < $1.name }.map { tool -> [String: Any] in
                ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema,
                 "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": false]]
            }
            respond(result: ["tools": listed], id: id, on: connection)

        case "tools/call":
            let toolName = parameters["name"] as? String ?? ""
            let arguments = parameters["arguments"] as? [String: Any] ?? [:]
            guard let tool = tools[toolName] else {
                send(jsonRPCError: -32602, message: "Unknown tool: \(toolName)", id: id, on: connection)
                return
            }
            Task { @MainActor in
                var text: String
                var isError = false
                do {
                    text = try await tool.handler(arguments)
                } catch {
                    text = "\(error)"
                    isError = true
                }
                self.respond(result: ["content": [["type": "text", "text": text]], "isError": isError],
                             id: id, on: connection)
            }

        default:
            send(jsonRPCError: -32601, message: "Method not found: \(method)", id: id, on: connection)
        }
    }

    // MARK: - Responses

    private func respond(result: [String: Any], id: Any, on connection: NWConnection) {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        send(status: "200 OK", body: data, contentType: "application/json", on: connection)
    }

    private func send(jsonRPCError code: Int, message: String, id: Any?, on connection: NWConnection) {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(),
                                      "error": ["code": code, "message": message]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        send(status: "200 OK", body: data, contentType: "application/json", on: connection)
    }

    private func send(status: String, body: Data, contentType: String = "text/plain", on connection: NWConnection) {
        var response = Data(("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in })
    }
}

/// Just enough HTTP to serve JSON-RPC over loopback.
struct HTTPRequest {
    let method: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// One request from the start of `buffer` and the bytes it used, or nil if incomplete.
    static func parse(_ buffer: Data) -> (HTTPRequest, Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)

        let request = HTTPRequest(method: String(requestLine[0]), headers: headers,
                                  body: Data(buffer[bodyStart..<bodyEnd]))
        return (request, buffer.distance(from: buffer.startIndex, to: bodyEnd))
    }
}
