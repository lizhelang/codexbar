import Foundation

/// Vendor-specific quirks the chat/completions translation gateway must honour.
///
/// Defaults match the most common OpenAI-compatible behaviour. Individual presets
/// override only the fields where the upstream deviates from that baseline.
struct CodexBarChatQuirks: Equatable {
    /// Path appended to the provider `baseURL` to reach the chat completions endpoint.
    var chatCompletionsPathSuffix: String
    /// Field name used to cap output tokens (`max_tokens` vs `max_completion_tokens`).
    var maxTokensField: String
    /// Flatten structured content arrays into a single string (some GLM endpoints require this).
    var flattenContent: Bool
    /// Downgrade an explicit `tool_choice` object to `"auto"` (GLM rejects forced tool choice).
    var toolChoiceDowngradeToAuto: Bool
    /// Upstream emits `reasoning_content` deltas (DeepSeek-R1, Kimi thinking, GLM thinking…).
    var supportsReasoning: Bool

    init(
        chatCompletionsPathSuffix: String = "/chat/completions",
        maxTokensField: String = "max_tokens",
        flattenContent: Bool = false,
        toolChoiceDowngradeToAuto: Bool = false,
        supportsReasoning: Bool = true
    ) {
        self.chatCompletionsPathSuffix = chatCompletionsPathSuffix
        self.maxTokensField = maxTokensField
        self.flattenContent = flattenContent
        self.toolChoiceDowngradeToAuto = toolChoiceDowngradeToAuto
        self.supportsReasoning = supportsReasoning
    }

    static let standard = CodexBarChatQuirks()
}

enum CodexBarProviderPresetGroup: String, CaseIterable, Identifiable {
    case domestic
    case foreign

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .domestic:
            return L.providerPresetGroupDomestic
        case .foreign:
            return L.providerPresetGroupForeign
        }
    }
}

enum CodexBarProviderPresetKind: Equatable {
    case openAICompatible
    case openRouter
}

struct CodexBarProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    let group: CodexBarProviderPresetGroup
    let kind: CodexBarProviderPresetKind
    let baseURL: String
    let wireAPI: CodexBarWireAPI
    let defaultModels: [CodexBarOpenRouterModel]
    let quirks: CodexBarChatQuirks
    /// Optional advisory shown in the UI (e.g. native protocol caveats).
    let note: String?

    init(
        id: String,
        displayName: String,
        group: CodexBarProviderPresetGroup,
        kind: CodexBarProviderPresetKind = .openAICompatible,
        baseURL: String,
        wireAPI: CodexBarWireAPI = .responses,
        defaultModels: [(String, String)] = [],
        quirks: CodexBarChatQuirks = .standard,
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.kind = kind
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.defaultModels = defaultModels.map { CodexBarOpenRouterModel(id: $0.0, name: $0.1) }
        self.quirks = quirks
        self.note = note
    }

    var defaultModelID: String? {
        self.defaultModels.first?.id
    }
}

enum CodexBarProviderPresetCatalog {
    static let all: [CodexBarProviderPreset] = domestic + foreign

    static let domestic: [CodexBarProviderPreset] = [
        CodexBarProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            group: .domestic,
            baseURL: "https://api.deepseek.com",
            wireAPI: .responses,
            defaultModels: [
                ("deepseek-flash", "DeepSeek Flash"),
                ("deepseek-v4-pro", "DeepSeek V4 Pro"),
            ]
        ),
        CodexBarProviderPreset(
            id: "zhipu-glm",
            displayName: "智谱 GLM",
            group: .domestic,
            baseURL: "https://open.bigmodel.cn/api/v1",
            wireAPI: .responses,
            defaultModels: [
                ("glm-5.3", "GLM-5.3"),
                ("glm-5-turbo", "GLM-5 Turbo"),
            ],
            quirks: CodexBarChatQuirks(
                flattenContent: true,
                toolChoiceDowngradeToAuto: true
            )
        ),
    ]

    static let foreign: [CodexBarProviderPreset] = [
        CodexBarProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            group: .foreign,
            kind: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            wireAPI: .responses,
            defaultModels: [
                ("anthropic/claude-3.7-sonnet", "Claude 3.7 Sonnet"),
                ("openai/gpt-4.1", "GPT-4.1"),
                ("google/gemini-2.5-pro", "Gemini 2.5 Pro"),
            ]
        ),
        CodexBarProviderPreset(
            id: "requesty",
            displayName: "Requesty",
            group: .foreign,
            baseURL: "https://router.requesty.ai/v1",
            wireAPI: .responses,
            defaultModels: [
                ("openai-responses/gpt-5", "GPT-5"),
                ("openai-responses/gpt-5-mini", "GPT-5 mini"),
                ("openai-responses/gpt-4.1", "GPT-4.1"),
            ]
        ),
    ]

    static func preset(id: String?) -> CodexBarProviderPreset? {
        guard let id, id.isEmpty == false else { return nil }
        return self.all.first { $0.id == id }
    }

    /// Resolve the chat quirks for a provider, falling back to the standard
    /// OpenAI-compatible behaviour for custom (preset-less) providers.
    static func quirks(forPresetID presetID: String?) -> CodexBarChatQuirks {
        if let preset = self.preset(id: presetID) {
            return preset.quirks
        }
        // 不再展示的旧预设仍保留必要协议差异，避免影响用户已保存的服务。
        switch presetID {
        case "moonshot-kimi", "minimax":
            return CodexBarChatQuirks(maxTokensField: "max_completion_tokens")
        default:
            return .standard
        }
    }
}

enum CodexBarProviderCompatibility {
    static func isDeepSeek(presetID: String?, baseURL: String) -> Bool {
        presetID == "deepseek" || URLComponents(
            string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )?.host?.lowercased() == "api.deepseek.com"
    }
}

/// A proposal only: the caller must show the endpoint/model changes before applying it.
struct CodexBarProviderResponsesMigration: Equatable {
    let baseURL: String
    let modelID: String

    static func proposal(for provider: CodexBarProvider) -> Self? {
        guard provider.kind == .openAICompatible, provider.wireAPI == .chat,
              let baseURL = provider.baseURL,
              let url = URLComponents(string: baseURL),
              url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let presetID: String
        switch (url.host?.lowercased(), path) {
        case ("api.deepseek.com", ""), ("api.deepseek.com", "v1"):
            presetID = "deepseek"
        case ("open.bigmodel.cn", "api/paas/v4"), ("open.bigmodel.cn", "api/v1"):
            presetID = "zhipu-glm"
        case ("router.requesty.ai", "v1"):
            presetID = "requesty"
        default:
            return nil
        }
        guard let preset = CodexBarProviderPresetCatalog.preset(id: presetID),
              preset.wireAPI == .responses, let defaultModel = preset.defaultModelID else {
            return nil
        }
        let currentModel = provider.compatibleEffectiveModelID
        let modelID = preset.defaultModels.first(where: { $0.id == currentModel })?.id ?? defaultModel
        return Self(baseURL: preset.baseURL, modelID: modelID)
    }
}
