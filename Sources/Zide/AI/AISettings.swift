import AppKit
import SwiftUI

// MARK: - Settings window

struct AISettingsView: View {
    @State private var config = AIConfig.current
    @State private var key = ""                  // empty = keep the saved key
    @State private var hint = AIConfig.keyHint
    @State private var models: [String] = []
    @State private var status = ""
    @State private var testing = false
    @AppStorage("aiInlineCompletions") private var inline = false

    var body: some View {
        Form {
            Section {
                Picker("Start from", selection: Binding(get: { "" }, set: { name in
                    if let p = AIConfig.presets.first(where: { $0.name == name }) { config = p.config; models = []; status = p.needsKey ? "Paste your API key below." : "No key needed." }
                })) {
                    Text("Choose a preset…").tag("")
                    ForEach(AIConfig.presets) { Text($0.name).tag($0.name) }
                }
                Picker("API format", selection: $config.format) { ForEach(AIConfig.Format.allCases) { Text($0.rawValue).tag($0) } }
                if config.format == .apple {
                    Label(AppleAI.available ? "Ready — free, private, runs on this Mac with no key. Answers are shorter than big cloud models, and it can't read images." : AppleAI.status,
                          systemImage: AppleAI.available ? "apple.intelligence" : "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(AppleAI.available ? Color.secondary : Color.orange)
                } else {
                TextField("Base URL", text: $config.baseURL).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Model", text: $config.model).textFieldStyle(.roundedBorder)
                    if !models.isEmpty {
                        Menu("Pick") { ForEach(models, id: \.self) { m in Button(m) { config.model = m } } }.fixedSize()
                    }
                    Button("Fetch List") { Task { models = await AIClient.listModels(config: config, key: AIConfig.clean(key).isEmpty ? AIConfig.apiKey : AIConfig.clean(key)); status = models.isEmpty ? "The server didn't list any models." : "\(models.count) models found." } }
                }
                HStack {
                    SecureField(hint.map { "Saved key \($0) — paste a new one to replace it" } ?? "API key (leave empty for Ollama / local servers)", text: $key).textFieldStyle(.roundedBorder)
                    if hint != nil { Button("Remove Key") { AIConfig.setKey(nil); hint = nil; key = ""; status = "Key removed." } }
                }
                Toggle("This model can read images (screenshots, diagrams)", isOn: $config.vision)
                }
            } footer: {
                Text("Works with Anthropic's API and any OpenAI-compatible server: Ollama, LM Studio, OmniRoute, OpenRouter, OpenAI and others. The key is kept in a private file only your user account can read, and sent only to the base URL above. The assistant reads your project through tools; models without tool support get the open file instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Inline completions (ghost text as you type; Tab accepts)", isOn: $inline)
                Text(inline && config.format != .apple && !(URL(string: config.baseURL)?.host.map { ["localhost", "127.0.0.1"].contains($0) } ?? false)
                     ? "Each pause in typing sends a request — with a paid API key this costs tokens. Apple Intelligence or a local model is free."
                     : "Suggestions appear after a short pause in typing. Esc dismisses them.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Editor") }
            HStack {
                Button("Save") { save(); status = "Saved." }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Test Connection") { test() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .padding(.bottom, 8)
    }

    /// Saves the settings; the key changes only when a new one was typed (an empty field keeps the saved key).
    private func save() {
        AIConfig.current = config
        if !AIConfig.clean(key).isEmpty { AIConfig.setKey(key); key = ""; hint = AIConfig.keyHint }
    }

    private func test() {
        save(); testing = true; status = "Asking \(config.model)…"
        Task {
            do {
                let r = try await AIClient.chat(system: "Answer in one short sentence.", messages: [AIMessage(role: "user", text: "Say hello to a programmer.")], maxTokens: 200)
                status = "✓ \(r.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))"
            } catch { status = "✗ \(error.localizedDescription)" }
            testing = false
        }
    }

    private static var window: NSWindow?
    @MainActor static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "AI Settings"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: AISettingsView())
        w.center(); window = w
        w.makeKeyAndOrderFront(nil)
    }
}
