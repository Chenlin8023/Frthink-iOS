import Foundation
import SwiftData

/// 一次请求的 token 用量（LlmStreamEvent 的三元组在这里有名字）
struct TokenUsage {
    var input: Int
    var output: Int
    var cached: Int

    var total: Int { input + output }

    static let zero = TokenUsage(input: 0, output: 0, cached: 0)
}

struct ModelPrice: Codable, Hashable {
    var input: Double     // 未命中缓存输入价 USD / 1M
    var output: Double    // 输出价 USD / 1M
    var cache: Double     // 命中缓存输入价 USD / 1M
}

/// 单价表（母版 lib/usage.js:4-11；用户可在 UserDefaults["usage.pricing"] 里整份覆盖）
struct UsagePricing: Codable {
    var cnyPerUSD: Double = 7.1
    var models: [String: ModelPrice] = UsagePricing.defaults

    static let storageKey = "usage.pricing"

    static var defaults: [String: ModelPrice] {
        [
            "deepseek-v4-pro": ModelPrice(input: 0.66, output: 1.98, cache: 0.02),
            "deepseek-flash": ModelPrice(input: 0.14, output: 0.42, cache: 0.01)
        ]
    }

    /// 当前生效单价（读取失败一律回内置默认）
    static var shared: UsagePricing {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(UsagePricing.self, from: data) else {
            return UsagePricing()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: UsagePricing.storageKey)
        }
    }

    /// 模型名 → 单价：精确命中 → 按母版的 flash 关键字回落 → 否则按高档价
    func price(for model: String) -> ModelPrice {
        let name = model.trimmingCharacters(in: .whitespaces)
        if let exact = models[name] { return exact }
        let lower = name.lowercased()
        if lower.contains("flash") || lower.contains("mini") || lower.contains("small")
            || lower.contains("haiku") || lower.contains("lite") {
            if let cheap = models["deepseek-flash"] { return cheap }
        }
        return models["deepseek-v4-pro"] ?? ModelPrice(input: 0.66, output: 1.98, cache: 0.02)
    }
}

/// 用量记账与聚合（reports/10 §5.7）
enum UsageService {

    struct StageStat {
        var tokens: Int = 0
        var costCNY: Double = 0
        var calls: Int = 0
    }

    struct Summary {
        var calls: Int = 0
        var tokens: Int = 0
        var cached: Int = 0
        var costCNY: Double = 0
        var byStage: [String: StageStat] = [:]
        var byChapter: [Int: StageStat] = [:]
    }

    /// 费用（母版公式：miss*in + hit*cache + out*out，单位 USD/1M → 折 CNY）
    static func costCNY(model: String, usage: TokenUsage, pricing: UsagePricing = UsagePricing.shared) -> Double {
        let p = pricing.price(for: model)
        let hit = max(0, min(usage.cached, usage.input))
        let miss = max(0, usage.input - hit)
        let usd = Double(miss) / 1_000_000 * p.input
            + Double(hit) / 1_000_000 * p.cache
            + Double(usage.output) / 1_000_000 * p.output
        return usd * pricing.cnyPerUSD
    }

    /// 记一条 usage。
    /// 约定：`task` 沿用老字段（写作/摘要/翻译/整理，设置页旧统计按它聚合），
    /// `stage` 是新字段（outline/state/check/remake/generate/review/selfcheck），两者都写。
    @discardableResult
    static func record(context: ModelContext,
                       credentialName: String,
                       model: String,
                       task: String,
                       stage: String,
                       chapterIndex: Int? = nil,
                       projectID: UUID? = nil,
                       usage: TokenUsage) -> UsageRecord {
        let row = UsageRecord(credentialName: credentialName,
                              model: model,
                              task: task,
                              inputTokens: usage.input,
                              outputTokens: usage.output,
                              cachedTokens: usage.cached)
        row.stage = stage
        row.chapterIndex = chapterIndex
        row.projectID = projectID
        row.costCNY = costCNY(model: model, usage: usage)
        context.insert(row)
        try? context.save()
        return row
    }

    /// 聚合（分阶段 + 分章）；老记录 stage 为 nil 时归到 "chat"
    static func summarize(_ records: [UsageRecord]) -> Summary {
        var out = Summary()
        for r in records {
            let tokens = r.inputTokens + r.outputTokens
            let cost = r.costCNY ?? costCNY(model: r.model,
                                            usage: TokenUsage(input: r.inputTokens,
                                                              output: r.outputTokens,
                                                              cached: r.cachedTokens))
            out.calls += 1
            out.tokens += tokens
            out.cached += r.cachedTokens
            out.costCNY += cost

            let stage = r.stage ?? "chat"
            var s = out.byStage[stage] ?? StageStat()
            s.tokens += tokens
            s.costCNY += cost
            s.calls += 1
            out.byStage[stage] = s

            if let ch = r.chapterIndex {
                var c = out.byChapter[ch] ?? StageStat()
                c.tokens += tokens
                c.costCNY += cost
                c.calls += 1
                out.byChapter[ch] = c
            }
        }
        return out
    }

    static func summarizeProject(_ records: [UsageRecord], projectID: UUID) -> Summary {
        summarize(records.filter { $0.projectID == nil || $0.projectID == projectID })
    }
}
