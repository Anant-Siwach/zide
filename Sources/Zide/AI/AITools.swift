import Foundation

// MARK: - Tool calling (Anthropic tool_use / OpenAI tool_calls)

struct AITool {
    let name: String
    let description: String
    let properties: [String: [String: Any]]
    let required: [String]
    var schema: [String: Any] { ["type": "object", "properties": properties, "required": required] }
}

extension AIClient {
    struct ToolsUnsupported: Error {}

    /// Runs a conversation in which the model may call tools; returns its final text.
    static func runWithTools(system: String, history: [AIMessage], user: String, tools: [AITool], config: AIConfig = .current, key: String? = AIConfig.apiKey,
                             maxSteps: Int = 10, call: @escaping (String, [String: Any]) async -> String) async throws -> String {
        if config.format == .apple { throw ToolsUnsupported() }      // the coach then sends its whole-game briefing
        func post(_ url: URL, _ body: [String: Any], anthropic: Bool) async throws -> [String: Any] {
            var req = URLRequest(url: url, timeoutInterval: 300)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            if anthropic {
                req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
                if let key, !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
                if url.host == "api.anthropic.com" { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
            } else if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var b = body
            if anthropic && url.host == "api.anthropic.com" { b["fallbacks"] = "default" }
            req.httpBody = try JSONSerialization.data(withJSONObject: b)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard code == 200, let json else {
                let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
                if code == 400 || code == 422 || code == 404, msg.lowercased().contains("tool") || msg.lowercased().contains("function") { throw ToolsUnsupported() }
                let sent = req.value(forHTTPHeaderField: "x-api-key") != nil || req.value(forHTTPHeaderField: "Authorization") != nil
                throw AIError(code == 401 || code == 403 ? (sent ? "The AI server rejected the API key (\(code)): \(msg)" : "No API key was sent (\(code)). Paste your key in AI Settings and press Save.") : "AI error \(code): \(msg)")
            }
            return json
        }
        switch config.format {
        case .apple: throw ToolsUnsupported()
        case .anthropic:
            guard let url = endpoint(config.baseURL, "/v1/messages") else { throw AIError("The base URL isn't valid.") }
            var msgs: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
            msgs.append(["role": "user", "content": user])
            let toolDefs = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] as [String: Any] }
            for _ in 0..<maxSteps {
                let r = try await post(url, ["model": config.model, "max_tokens": 16000, "system": system, "messages": msgs, "tools": toolDefs], anthropic: true)
                if r["stop_reason"] as? String == "refusal" { throw AIError("The model declined to answer this request.") }
                let content = r["content"] as? [[String: Any]] ?? []
                let uses = content.filter { $0["type"] as? String == "tool_use" }
                if uses.isEmpty || r["stop_reason"] as? String != "tool_use" {
                    let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                    return text.isEmpty ? "(no answer)" : text
                }
                // Pass the assistant turn back unchanged (thinking blocks included), then every result in one user turn.
                msgs.append(["role": "assistant", "content": content])
                var results: [[String: Any]] = []
                for u in uses {
                    let out = await call(u["name"] as? String ?? "", u["input"] as? [String: Any] ?? [:])
                    results.append(["type": "tool_result", "tool_use_id": u["id"] as? String ?? "", "content": out])
                }
                msgs.append(["role": "user", "content": results])
            }
            throw AIError("The coach used too many steps without finishing.")
        case .openai:
            guard let url = endpoint(config.baseURL, "/chat/completions") else { throw AIError("The base URL isn't valid.") }
            var msgs: [[String: Any]] = [["role": "system", "content": system]] + history.map { ["role": $0.role, "content": $0.text] }
            msgs.append(["role": "user", "content": user])
            let toolDefs = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]] as [String: Any] }
            for _ in 0..<maxSteps {
                let r = try await post(url, ["model": config.model, "messages": msgs, "tools": toolDefs, "stream": false], anthropic: false)
                guard let msg = ((r["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else { throw AIError("Unexpected reply from the server.") }
                let calls = msg["tool_calls"] as? [[String: Any]] ?? []
                if calls.isEmpty { return (msg["content"] as? String) ?? "(no answer)" }
                msgs.append(msg)
                for (i, c) in calls.enumerated() {
                    let f = c["function"] as? [String: Any] ?? [:]
                    var args: [String: Any] = f["arguments"] as? [String: Any] ?? [:]          // Ollama sends an object
                    if let s = f["arguments"] as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { args = o }
                    let out = await call(f["name"] as? String ?? "", args)
                    msgs.append(["role": "tool", "tool_call_id": c["id"] as? String ?? "call_\(i)", "name": f["name"] as? String ?? "", "content": out])
                }
            }
            throw AIError("The coach used too many steps without finishing.")
        }
    }
}

