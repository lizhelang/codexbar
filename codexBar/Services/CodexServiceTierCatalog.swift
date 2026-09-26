import Foundation

/// Codex 自己维护的模型目录缓存（`~/.codex/models_cache.json`）中与服务档位相关的部分。
///
/// Codex 每次启动都会从后端拉取模型目录并写入这份缓存，之后完全按其中的 `service_tiers`
/// 决定某个 `service_tier` 是否可以随请求发出。codexbar 直接读取同一份数据，
/// 这样菜单里可选的档位、以及同步进 `config.toml` 的值，都会随 Codex 后端自动调整，
/// 而不是依赖写死的名单。
struct CodexServiceTierCatalog: Equatable {
    struct Tier: Equatable, Hashable {
        let id: String
        let name: String
        let description: String
    }

    struct Model: Equatable {
        let slug: String
        /// 目录声明的默认档位；为 `nil` 时不设置 `service_tier` 即为标准路由。
        let defaultServiceTier: String?
        let serviceTiers: [Tier]
    }

    let models: [Model]
    let fetchedAt: Date?

    /// 读取磁盘上的缓存；文件缺失或无法解析时返回 `nil`，调用方应退回内置兜底档位。
    static func load(from url: URL = CodexPaths.modelsCacheURL) -> CodexServiceTierCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CodexServiceTierCatalog {
        let decoder = JSONDecoder()
        let payload = try decoder.decode(CachePayload.self, from: data)
        let models = payload.models.compactMap { entry -> Model? in
            guard let slug = Self.normalizedModelID(entry.slug) else { return nil }
            let tiers = (entry.serviceTiers ?? []).compactMap { tier -> Tier? in
                let id = tier.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard id.isEmpty == false else { return nil }
                return Tier(
                    id: id,
                    name: tier.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id,
                    description: tier.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            }
            let defaultTier = entry.defaultServiceTier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return Model(
                slug: slug,
                defaultServiceTier: defaultTier?.isEmpty == false ? defaultTier : nil,
                serviceTiers: Self.uniqueTiers(tiers)
            )
        }
        return CodexServiceTierCatalog(
            models: models,
            fetchedAt: payload.fetchedAt.flatMap(Self.parseDate)
        )
    }

    func model(for modelID: String) -> Model? {
        guard let normalized = Self.normalizedModelID(modelID) else { return nil }
        return self.models.first { $0.slug == normalized }
    }

    /// 返回 codexbar 内部使用的档位值；模型不在目录中时返回 `nil`。
    /// 结果始终以标准档位开头，其余按目录顺序排列（目录里的 `priority` 会映射为 `fast`）。
    func serviceTierOptions(for modelID: String) -> [String]? {
        guard let model = self.model(for: modelID) else { return nil }
        var options = [CodexBarGlobalSettings.standardServiceTier]
        for tier in model.serviceTiers {
            let value = CodexBarGlobalSettings.serviceTierValue(forCatalogTierID: tier.id)
            if options.contains(value) == false {
                options.append(value)
            }
        }
        return options
    }

    // MARK: - Decoding

    private struct CachePayload: Decodable {
        let fetchedAt: String?
        let models: [ModelEntry]

        enum CodingKeys: String, CodingKey {
            case fetchedAt = "fetched_at"
            case models
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.fetchedAt = try container.decodeIfPresent(String.self, forKey: .fetchedAt)
            if let list = try? container.decode([LossyModelEntry].self, forKey: .models) {
                self.models = list.compactMap(\.entry)
            } else if let keyed = try? container.decode([String: LossyModelEntry].self, forKey: .models) {
                self.models = keyed.compactMap(\.value.entry)
            } else {
                self.models = []
            }
        }
    }

    /// 单个模型条目解析失败时跳过，不让整份目录作废。
    private struct LossyModelEntry: Decodable {
        let entry: ModelEntry?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.entry = try? container.decode(ModelEntry.self)
        }
    }

    private struct ModelEntry: Decodable {
        let slug: String
        let defaultServiceTier: String?
        let serviceTiers: [TierEntry]?

        enum CodingKeys: String, CodingKey {
            case slug
            case defaultServiceTier = "default_service_tier"
            case serviceTiers = "service_tiers"
        }
    }

    private struct TierEntry: Decodable {
        let id: String
        let name: String?
        let description: String?
    }

    private static func normalizedModelID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func uniqueTiers(_ tiers: [Tier]) -> [Tier] {
        var seen: Set<String> = []
        return tiers.filter { seen.insert($0.id).inserted }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
