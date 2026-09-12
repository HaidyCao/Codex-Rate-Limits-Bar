import Darwin
import Foundation

enum CodexMCPServer {
    static func run() {
        let activity = MCPActivity()
        let timer = makeIdleTimer(activity: activity)
        timer?.resume()
        defer { timer?.cancel() }

        while let line = readLine() {
            activity.beginHandling()
            defer { activity.endHandling() }

            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  message.keys.contains("id")
            else {
                continue
            }
            handle(message)
        }
    }

    private static func makeIdleTimer(activity: MCPActivity) -> DispatchSourceTimer? {
        let timeout = idleTimeout()
        guard timeout > 0 else { return nil }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let timeoutInterval = DispatchTimeInterval.milliseconds(Int(timeout * 1000))
        let repeatSeconds = min(30, max(5, timeout / 4))
        let repeatInterval = DispatchTimeInterval.milliseconds(Int(repeatSeconds * 1000))
        timer.schedule(deadline: .now() + timeoutInterval, repeating: repeatInterval)
        timer.setEventHandler {
            guard activity.shouldExit(timeout: timeout) else { return }
            appendSharedLog("mcp idle exit after \(Int(timeout))s")
            Darwin.exit(0)
        }
        return timer
    }

    private static func idleTimeout() -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["CODEX_MCP_IDLE_TIMEOUT_SECONDS"],
              let value = TimeInterval(raw)
        else {
            return 300
        }
        return max(0, value)
    }

    private final class MCPActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()
        private var activeRequests = 0

        func beginHandling() {
            lock.lock()
            activeRequests += 1
            lastActivity = Date()
            lock.unlock()
        }

        func endHandling() {
            lock.lock()
            activeRequests = max(0, activeRequests - 1)
            lastActivity = Date()
            lock.unlock()
        }

        func shouldExit(timeout: TimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return activeRequests == 0 && Date().timeIntervalSince(lastActivity) >= timeout
        }
    }

    private static func handle(_ message: [String: Any]) {
        let id = message["id"] ?? NSNull()
        let method = stringValue(message["method"])
        if method == "initialize" {
            respond(id: id, result: [
                "protocolVersion": dictionaryValue(message["params"]).flatMap { stringValue($0["protocolVersion"]) } ?? "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "codex-usage-monitor", "version": "0.4.0"],
            ])
            return
        }
        if method == "tools/list" {
            respond(id: id, result: ["tools": tools()])
            return
        }
        if method == "tools/call" {
            let params = dictionaryValue(message["params"]) ?? [:]
            let name = stringValue(params["name"]) ?? ""
            do {
                let text: String
                switch name {
                case "get_codex_status":
                    text = try prettyJSON(CodexBackend.readStatus())
                case "get_codex_rate_limits":
                    text = try prettyJSON(CodexBackend.readRateLimits())
                case "get_codex_local_usage":
                    text = try prettyJSON(CodexBackend.readLocalTokenUsage())
                case "get_codex_account_usage":
                    text = try prettyJSON(CodexBackend.readTokenUsage())
                case "get_codex_reset_credits":
                    text = try prettyJSON(CodexBackend.readResetCredits())
                default:
                    respondError(id: id, code: -32602, message: "Unknown tool: \(name)")
                    return
                }
                respond(id: id, result: ["content": [["type": "text", "text": text]]])
            } catch {
                respondError(id: id, code: -32000, message: errorMessage(error))
            }
            return
        }
        if method == "ping" {
            respond(id: id, result: [:])
            return
        }
        respondError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
    }

    private static func emptyInputSchema() -> [String: Any] {
        ["type": "object", "properties": [:], "additionalProperties": false]
    }

    private static func tools() -> [[String: Any]] {
        [
            [
                "name": "get_codex_status",
                "description": "Read Codex rate limits, local token usage, daily API-equivalent cost, estimated Codex credits, official credit balance when available, and the local weekly quota value estimate.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_rate_limits",
                "description": "Read the current Codex weekly rate-limit snapshot.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_local_usage",
                "description": "Read today's local Codex token usage, API-equivalent cost and token-based credit estimates with pricing coverage from desktop and CLI session logs. Credit estimates are not actual deductions.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_account_usage",
                "description": "Read Codex account token usage summary and daily usage buckets from the local Codex app-server.",
                "inputSchema": emptyInputSchema(),
            ],
            [
                "name": "get_codex_reset_credits",
                "description": "Read available Codex rate-limit reset credits and their expiration times from the local Codex auth session.",
                "inputSchema": emptyInputSchema(),
            ],
        ]
    }

    private static func respond(id: Any, result: Any) {
        writeJSONObject(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func respondError(id: Any, code: Int, message: String) {
        writeJSONObject(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func writeJSONObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}
