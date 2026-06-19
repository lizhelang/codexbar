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
        wireAPI: CodexBarWireAPI = .chat,
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
            baseURL: "https://api.deepseek.com/v1",
            defaultModels: [
                ("deepseek-chat", "DeepSeek Chat"),
                ("deepseek-reasoner", "DeepSeek Reasoner"),
            ]
        ),
        CodexBarProviderPreset(
            id: "zhipu-glm",
            displayName: "智谱 GLM",
            group: .domestic,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModels: [
                ("glm-4.6", "GLM-4.6"),
                ("glm-4.5", "GLM-4.5"),
                ("glm-4.5-air", "GLM-4.5 Air"),
            ],
            quirks: CodexBarChatQuirks(
                flattenContent: true,
                toolChoiceDowngradeToAuto: true
            )
        ),
        CodexBarProviderPreset(
            id: "moonshot-kimi",
            displayName: "Kimi (月之暗面)",
            group: .domestic,
            baseURL: "https://api.moonshot.cn/v1",
            defaultModels: [
                ("kimi-k2-0905-preview", "Kimi K2"),
                ("moonshot-v1-128k", "Moonshot v1 128k"),
            ],
            quirks: CodexBarChatQuirks(maxTokensField: "max_completion_tokens")
        ),
        CodexBarProviderPreset(
            id: "qwen-dashscope",
            displayName: "通义千问 (百炼)",
            group: .domestic,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModels: [
                ("qwen3-coder-plus", "Qwen3 Coder Plus"),
                ("qwen-max", "Qwen Max"),
                ("qwen-plus", "Qwen Plus"),
            ]
        ),
        CodexBarProviderPreset(
            id: "minimax",
            displayName: "MiniMax",
            group: .domestic,
            baseURL: "https://api.minimaxi.com/v1",
            defaultModels: [
                ("MiniMax-Text-01", "MiniMax Text 01"),
                ("abab6.5s-chat", "abab6.5s"),
            ],
            quirks: CodexBarChatQuirks(maxTokensField: "max_completion_tokens")
        ),
        CodexBarProviderPreset(
            id: "doubao-ark",
            displayName: "豆包 (火山方舟)",
            group: .domestic,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            defaultModels: [
                ("doubao-seed-1-6-250615", "Doubao Seed 1.6"),
                ("doubao-pro-32k", "Doubao Pro 32k"),
            ],
            note: L.providerPresetNoteArkEndpoint
        ),
        CodexBarProviderPreset(
            id: "siliconflow",
            displayName: "硅基流动 SiliconFlow",
            group: .domestic,
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModels: [
                ("deepseek-ai/DeepSeek-V3", "DeepSeek V3"),
                ("Qwen/Qwen2.5-Coder-32B-Instruct", "Qwen2.5 Coder 32B"),
            ]
        ),
        CodexBarProviderPreset(
            id: "stepfun",
            displayName: "阶跃星辰 StepFun",
            group: .domestic,
            baseURL: "https://api.stepfun.com/v1",
            defaultModels: [
                ("step-2-16k", "Step-2 16k"),
            ]
        ),
        CodexBarProviderPreset(
            id: "lingyiwanwu",
            displayName: "零一万物 Yi",
            group: .domestic,
            baseURL: "https://api.lingyiwanwu.com/v1",
            defaultModels: [
                ("yi-large", "Yi Large"),
                ("yi-large-turbo", "Yi Large Turbo"),
            ]
        ),
        CodexBarProviderPreset(
            id: "hunyuan",
            displayName: "腾讯混元",
            group: .domestic,
            baseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            defaultModels: [
                ("hunyuan-turbo", "Hunyuan Turbo"),
                ("hunyuan-pro", "Hunyuan Pro"),
            ]
        ),
        CodexBarProviderPreset(
            id: "spark",
            displayName: "讯飞星火",
            group: .domestic,
            baseURL: "https://spark-api-open.xf-yun.com/v1",
            defaultModels: [
                ("4.0Ultra", "Spark 4.0 Ultra"),
                ("generalv3.5", "Spark v3.5"),
            ]
        ),
        CodexBarProviderPreset(
            id: "baichuan",
            displayName: "百川 Baichuan",
            group: .domestic,
            baseURL: "https://api.baichuan-ai.com/v1",
            defaultModels: [
                ("Baichuan4", "Baichuan4"),
            ]
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
            id: "openai-apikey",
            displayName: "OpenAI (API Key)",
            group: .foreign,
            baseURL: "https://api.openai.com/v1",
            wireAPI: .responses,
            defaultModels: [
                ("gpt-5-codex", "GPT-5 Codex"),
                ("gpt-5", "GPT-5"),
                ("o4-mini", "o4-mini"),
            ]
        ),
        CodexBarProviderPreset(
            id: "groq",
            displayName: "Groq",
            group: .foreign,
            baseURL: "https://api.groq.com/openai/v1",
            defaultModels: [
                ("llama-3.3-70b-versatile", "Llama 3.3 70B"),
                ("deepseek-r1-distill-llama-70b", "DeepSeek R1 Distill 70B"),
            ]
        ),
        CodexBarProviderPreset(
            id: "xai",
            displayName: "xAI Grok",
            group: .foreign,
            baseURL: "https://api.x.ai/v1",
            defaultModels: [
                ("grok-2-latest", "Grok 2"),
                ("grok-beta", "Grok Beta"),
            ]
        ),
        CodexBarProviderPreset(
            id: "mistral",
            displayName: "Mistral",
            group: .foreign,
            baseURL: "https://api.mistral.ai/v1",
            defaultModels: [
                ("codestral-latest", "Codestral"),
                ("mistral-large-latest", "Mistral Large"),
            ]
        ),
        CodexBarProviderPreset(
            id: "together",
            displayName: "Together AI",
            group: .foreign,
            baseURL: "https://api.together.xyz/v1",
            defaultModels: [
                ("deepseek-ai/DeepSeek-V3", "DeepSeek V3"),
                ("Qwen/Qwen2.5-Coder-32B-Instruct", "Qwen2.5 Coder 32B"),
            ]
        ),
        CodexBarProviderPreset(
            id: "fireworks",
            displayName: "Fireworks AI",
            group: .foreign,
            baseURL: "https://api.fireworks.ai/inference/v1",
            defaultModels: [
                ("accounts/fireworks/models/deepseek-v3", "DeepSeek V3"),
            ]
        ),
        CodexBarProviderPreset(
            id: "deepinfra",
            displayName: "DeepInfra",
            group: .foreign,
            baseURL: "https://api.deepinfra.com/v1/openai",
            defaultModels: [
                ("deepseek-ai/DeepSeek-V3", "DeepSeek V3"),
            ]
        ),
        CodexBarProviderPreset(
            id: "perplexity",
            displayName: "Perplexity",
            group: .foreign,
            baseURL: "https://api.perplexity.ai",
            defaultModels: [
                ("sonar-pro", "Sonar Pro"),
                ("sonar", "Sonar"),
            ]
        ),
        CodexBarProviderPreset(
            id: "gemini-openai",
            displayName: "Gemini (OpenAI 兼容)",
            group: .foreign,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModels: [
                ("gemini-2.5-pro", "Gemini 2.5 Pro"),
                ("gemini-2.0-flash", "Gemini 2.0 Flash"),
            ],
            note: L.providerPresetNoteGeminiCompat
        ),
    ]

    static func preset(id: String?) -> CodexBarProviderPreset? {
        guard let id, id.isEmpty == false else { return nil }
        return self.all.first { $0.id == id }
    }

    /// Resolve the chat quirks for a provider, falling back to the standard
    /// OpenAI-compatible behaviour for custom (preset-less) providers.
    static func quirks(forPresetID presetID: String?) -> CodexBarChatQuirks {
        self.preset(id: presetID)?.quirks ?? .standard
    }
}
