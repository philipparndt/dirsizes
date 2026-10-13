import DirScanner
import Foundation

/// `dirsizes mcp`: an MCP server on stdio that forwards every message to the running app's
/// HTTP server, and starts the app when it isn't running. MCP clients launch this command, so
/// their config needs neither a port nor a token.
func runMCPBridge() -> Never {
    while let line = readLine(strippingNewline: true) {
        guard !line.allSatisfy(\.isWhitespace) else { continue }
        if let reply = forward(line), !reply.isEmpty {
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
    exit(0)
}

private func forward(_ message: String) -> String? {
    guard let endpoint = MCPEndpoint.read() ?? launchApp() else {
        return errorReply(to: message, "DirSizes is not running and could not be started.")
    }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/mcp")!)
    request.httpMethod = "POST"
    request.httpBody = Data(message.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
    // A scan can take minutes on a big disk.
    request.timeoutInterval = 900

    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var reply: String?
    nonisolated(unsafe) var failure: String?
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            failure = error.localizedDescription
        } else if let status = (response as? HTTPURLResponse)?.statusCode, status >= 300, status != 202 {
            failure = "HTTP \(status)"
        } else {
            reply = data.map { String(decoding: $0, as: UTF8.self) }
        }
        done.signal()
    }.resume()
    done.wait()

    if let failure { return errorReply(to: message, "DirSizes did not answer: \(failure)") }
    return reply
}

/// Starts the app this CLI ships in (or, outside a bundle, whichever copy macOS knows) without
/// bringing it to the front, then waits for it to publish its endpoint.
private func launchApp() -> MCPEndpoint? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var bundle = executable
    while bundle.path != "/" && bundle.pathExtension != "app" { bundle.deleteLastPathComponent() }

    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", "de.rnd7.dirsizes"]
    guard (try? open.run()) != nil else { return nil }
    open.waitUntilExit()

    for _ in 0..<100 {
        if let endpoint = MCPEndpoint.read() { return endpoint }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

/// A JSON-RPC error for a request; notifications (no id) get no reply.
private func errorReply(to message: String, _ text: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
          let id = object["id"]
    else { return nil }
    let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]]
    return (try? JSONSerialization.data(withJSONObject: payload)).map { String(decoding: $0, as: UTF8.self) }
}
