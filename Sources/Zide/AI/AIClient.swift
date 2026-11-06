import AppKit
import Security
import SwiftUI

// MARK: - Any AI provider (shared design with Zbase): Anthropic's Messages API, or any OpenAI-compatible server (Ollama, OmniRoute,
// OpenRouter, LM Studio, OpenAI…). Configured by base URL + model + optional key; the key lives in the Keychain.

struct AIConfig: Codable, Equatable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case anthropic = "Anthropic (Messages API)", openai = "OpenAI-compatible (chat/completions)", apple = "Apple Intelligence (on this Mac)"
        var id: String { rawValue }
    }
    var format: Format = .anthropic
    var baseURL = "https://api.anthropic.com"
    var model = "claude-opus-5-5"
    var vision = true            // the model can read images (for position-from-screenshot)

    struct Preset: Identifiable { let name: String; let config: AIConfig; let needsKey: Bool; var id: String { name } }
    static let presets: [Preset] = [
        Preset(name: "Apple Intelligence (on this Mac, free)", config: AIConfig(format: .apple, baseURL: "", model: "Apple on-device model", vision: false), needsKey: false),
        Preset(name: "Anthropic (Claude)", config: AIConfig(format: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5", vision: true), needsKey: true),
        Preset(name: "Ollama (local)", config: AIConfig(format: .openai, baseURL: "http://localhost:11434/v1", model: "llama3.1", vision: false), needsKey: false),
        Preset(name: "LM Studio (local)", config: AIConfig(format: .openai, baseURL: "http://localhost:1234/v1", model: "local-model", vision: false), needsKey: false),
        Preset(name: "OpenRouter", config: AIConfig(format: .openai, baseURL: "https://openrouter.ai/api/v1", model: "anthropic/claude-opus-5-5", vision: true), needsKey: true),
        Preset(name: "OpenAI", config: AIConfig(format: .openai, baseURL: "https://api.openai.com/v1", model: "gpt-5", vision: true), needsKey: true),
        Preset(name: "OmniRoute / other gateway", config: AIConfig(format: .openai, baseURL: "http://localhost:20128/v1", model: "auto", vision: true), needsKey: true),
    ]

    static var current: AIConfig {
        get {
            // Self-tests point the coach at a local mock server without touching your settings.
            if ProcessInfo.processInfo.environment["ZIDE_AI_APPLE"] != nil { return AIConfig(format: .apple, baseURL: "", model: "Apple on-device model", vision: false) }
            if let mock = ProcessInfo.processInfo.environment["ZIDE_AI_MOCK"] { return AIConfig(format: .openai, baseURL: mock, model: "mock-small", vision: true) }
            return UserDefaults.standard.data(forKey: "aiConfig").flatMap { try? JSONDecoder().decode(AIConfig.self, from: $0) } ?? AIConfig()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "aiConfig") }
    }
    static var isConfigured: Bool { ProcessInfo.processInfo.environment["ZIDE_AI_MOCK"] != nil || ProcessInfo.processInfo.environment["ZIDE_AI_APPLE"] != nil || UserDefaults.standard.data(forKey: "aiConfig") != nil }

    // MARK: Key storage
    // A private file (readable only by your user account, like other developer tools' key files). The Keychain asked
    // for your password on every launch because the app's self-made signature changes with each build.
    private static let service = "com.zide.ai"
    nonisolated(unsafe) private static var cached: String??
    private static let lock = NSLock()
    static var keyFile: URL {
        let base = ProcessInfo.processInfo.environment["ZIDE_TESTDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zide")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("ai-key")
    }
    static var apiKey: String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        var k = (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if k?.isEmpty ?? true { k = nil }
        cached = .some(k)
        return k
    }
    static func setKey(_ key: String?) {
        let k = clean(key ?? "")
        lock.lock(); defer { lock.unlock() }
        if k.isEmpty { try? FileManager.default.removeItem(at: keyFile) }
        else {
            FileManager.default.createFile(atPath: keyFile.path, contents: Data(k.utf8), attributes: [.posixPermissions: 0o600])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        }
        cached = .some(k.isEmpty ? nil : k)
        // Remove any old Keychain copy so it never prompts again.
        if ProcessInfo.processInfo.environment["ZIDE_TESTDIR"] == nil { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
    }
    /// Pasted keys often carry quotes, spaces or a "Bearer " prefix.
    static func clean(_ s: String) -> String {
        var k = s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if k.lowercased().hasPrefix("bearer ") { k = String(k.dropFirst(7)) }
        return k.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var keyHint: String? { apiKey.map { "…" + String($0.suffix(4)) } }
}

struct AIMessage: Codable { var role: String; var text: String; var imagePNG: Data? = nil }

enum AIClient {
    struct AIError: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }

    /// "https://x" + "/v1/messages", tolerating a base that already ends in /v1.
    static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if path.hasPrefix("/v1/") && b.hasSuffix("/v1") { b.removeLast(3) }
        return URL(string: b + path)
    }

    static func chat(system: String, messages: [AIMessage], config: AIConfig = .current, key: String? = AIConfig.apiKey, maxTokens: Int = 16000) async throws -> String {
        if config.format == .apple { return try await AppleAI.chat(system: system, messages: messages) }
        var req: URLRequest
        var body: [String: Any]
        switch config.format {
        case .apple: fatalError()
        case .anthropic:
            guard let url = endpoint(config.baseURL, "/v1/messages") else { throw AIError("The base URL isn't valid.") }
            req = URLRequest(url: url, timeoutInterval: 300)
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            if let key, !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
            body = ["model": config.model, "max_tokens": maxTokens, "system": system,
                    "messages": messages.map { m -> [String: Any] in
                        var content: [[String: Any]] = []
                        if let png = m.imagePNG { content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]) }
                        content.append(["type": "text", "text": m.text])
                        return ["role": m.role, "content": content]
                    }]
            // On Anthropic's own API, a request a safety classifier declines is retried on a suitable model automatically.
            if url.host == "api.anthropic.com" {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openai:
            guard let url = endpoint(config.baseURL, "/chat/completions") else { throw AIError("The base URL isn't valid.") }
            req = URLRequest(url: url, timeoutInterval: 300)
            if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            for m in messages {
                if let png = m.imagePNG {
                    msgs.append(["role": m.role, "content": [["type": "text", "text": m.text],
                                                             ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(png.base64EncodedString())"]]]])
                } else { msgs.append(["role": m.role, "content": m.text]) }
            }
            body = ["model": config.model, "messages": msgs, "stream": false]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AIError("Couldn't reach \(req.url?.host ?? "the AI server"): \(error.localizedDescription)") }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard code == 200, let json else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            let sent = req.value(forHTTPHeaderField: "x-api-key") != nil || req.value(forHTTPHeaderField: "Authorization") != nil
            throw AIError(code == 401 || code == 403 ? (sent ? "The AI server rejected the API key (\(code)): \(msg)" : "No API key was sent (\(code)). Paste your key in AI Settings and press Save.") :
                          code == 404 ? "Not found (404) — check the base URL and model name. \(msg)" : "AI error \(code): \(msg)")
        }
        switch config.format {
        case .apple: return ""
        case .anthropic:
            if json["stop_reason"] as? String == "refusal" { throw AIError("The model declined to answer this request.") }
            let text = ((json["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AIError("The model returned no text.") }
            return text
        case .openai:
            guard let choice = (json["choices"] as? [[String: Any]])?.first, let msg = choice["message"] as? [String: Any] else { throw AIError("Unexpected reply from the server.") }
            if let t = msg["content"] as? String, !t.isEmpty { return t }
            if let parts = msg["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
            throw AIError("The model returned no text.")
        }
    }

    /// Model names the server offers (OpenAI-compatible /models, or Anthropic /v1/models).
    static func listModels(config: AIConfig, key: String?) async -> [String] {
        if config.format == .apple { return ["Apple on-device model"] }
        let url = config.format == .anthropic ? endpoint(config.baseURL, "/v1/models") : endpoint(config.baseURL, "/models")
        guard let url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if config.format == .anthropic {
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            if let key, !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
        } else if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}

