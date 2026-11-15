import Foundation
import SwiftData

// MARK: - 槽位

enum AiSlot: String {
    case writer     // 写正文（贵模型）
    case worker     // 杂务：审校 / 状态档 / 打标 / 简介（便宜模型）
}

/// 一个 AI 任务的运行规格。
/// 关思考（母版 llm.js:42 的 enable_thinking:false）在这里靠"便宜槽 + 低温度 + JSON nudge"实现，
/// 不改 LlmClient（reports/10 §1.2 A/B 方案）。
struct AiTaskSpec {
    var slot: AiSlot = .writer
    var temperature: Double? = 1.0
    var maxTokens: Int? = nil
    var stage: String = "studio"          // 落 UsageRecord.stage
    var taskLabel: String = "写作"         // 落 UsageRecord.task（老字段，设置页旧统计用）
    var chapterIndex: Int? = nil
    var jsonRetries: Int = 0
}

// MARK: - 结束原因（content_filter 归因在这里）

/// Provider 侧的结束原因。`length` 与 `contentFilter` 在流上都表现为"突然结束"，
/// 只有 finish_reason 能区分；混为一谈会把"被服务端截断"误判成"模型写得太短"。
enum AiFinishKind: Equatable {
    case stop
    case length            // max_tokens 打满（母版 24k→32k 重试治的就是它）
    case contentFilter     // 服务端内容策略掐流
    case stopped           // 用户/任务取消
    case error(String)     // 中途 error 帧或网络错误
    case other(String)

    static func classify(_ reason: String?) -> AiFinishKind {
        guard let r = reason, !r.isEmpty else { return .other("") }
        if r.hasPrefix("error:") { return .error(String(r.dropFirst(6))) }
        switch r {
        case "stop", "end_turn", "eos":
            return .stop
        case "length", "max_tokens", "max_output_tokens":
            return .length
        case "content_filter", "content-filter", "sensitive", "SAFETY", "safety":
            return .contentFilter
        case "stopped":
            return .stopped
        default:
            return .other(r)
        }
    }

    /// 属于"没写完"的两种情况（正文可能只有半截）
    var isTruncated: Bool {
        switch self {
        case .length, .contentFilter: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .stop: return "正常结束"
        case .length: return "输出达到 max_tokens 上限"
        case .contentFilter: return "服务端按内容策略截断（content_filter）"
        case .stopped: return "已停止"
        case .error(let m): return "出错：\(m)"
        case .other(let r): return r.isEmpty ? "未知结束原因" : "结束原因 \(r)"
        }
    }
}

struct AiResult {
    var text: String
    var thinking: String
    var finish: AiFinishKind
    var rawFinishReason: String
    var usage: TokenUsage?
    var model: String
    var credentialName: String

    /// 上屏用的一行诊断（含 token 与结束原因）
    var diagnosis: String {
        var parts: [String] = [finish.label]
        if let u = usage {
            parts.append("in \(u.input) / out \(u.output) / cache \(u.cached)")
        }
        parts.append("model \(model)")
        return parts.joined(separator: " · ")
    }
}

enum AiError: LocalizedError {
    case busy
    case noCredential
    case emptyModel
    case server(String)
    case badJSON(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "已有 AI 请求在跑（LlmClient 是单例流，同一时刻只能有一个）。等它结束再发起。"
        case .noCredential:
            return "还没有可用凭证：设置 → 凭证管理"
        case .emptyModel:
            return "模型名未填写：设置 → 模型（写作模型 / 杂务模型）"
        case .server(let msg):
            return "服务返回错误：\(msg)"
        case .badJSON(let snippet):
            return "模型没有返回可解析的 JSON，原始片段=\(snippet)"
        }
    }
}

// MARK: - 线程安全的小工具

/// 流式增量收集器（LlmClient 的 onEvent 在后台线程回调，这里加锁）
final class AiStreamCollector {
    private let lock = NSLock()
    private var buf = ""
    private var think = ""

    var content: String {
        lock.lock(); defer { lock.unlock() }
        return buf
    }

    var thinking: String {
        lock.lock(); defer { lock.unlock() }
        return think
    }

    func appendContent(_ s: String) {
        lock.lock(); buf += s; lock.unlock()
    }

    func appendThinking(_ s: String) {
        lock.lock(); think += s; lock.unlock()
    }
}

/// continuation 只能 resume 一次（v1.8 双 resume 崩溃护栏的等价物）
final class AiOnceFlag {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - 唯一 LLM 出口

/// 所有 AI 任务都走这里：槽位解析、串行化、单次 resume、usage 记账、JSON 重试。
/// LlmClient.swift 一行不改（reports/10 hard rule）。
enum AiRunner {

    private static let lock = NSLock()
    private static var busy = false

    static var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return busy
    }

    private static func acquire() throws {
        lock.lock(); defer { lock.unlock() }
        if busy { throw AiError.busy }
        busy = true
    }

    private static func release() {
        lock.lock(); busy = false; lock.unlock()
    }

    /// 槽位 → 凭证+模型名。worker 槽回落链：workerModel → extractModel → 凭证默认模型。
    /// 注意：不标 @MainActor，UI 的同步计算属性里也要能读它；它只读 SettingsStore，无 UI 副作用。
    static func resolve(slot: AiSlot) -> (credential: ApiCredential, model: String)? {
        guard var cred = SettingsStore.shared.activeCredential else { return nil }
        let settings = SettingsStore.shared
        var name = ""
        switch slot {
        case .writer:
            name = settings.writingModel
        case .worker:
            if !settings.workerModel.isEmpty {
                name = settings.workerModel
            } else if !settings.extractModel.isEmpty {
                name = settings.extractModel
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { cred.model = trimmed }
        return (cred, cred.model)
    }

    /// 停止当前流（等价 LlmClient.stop；由 UI 的「停止」按钮调用）
    static func cancelCurrent() {
        LlmClient.shared.stop()
    }

    // MARK: 单次请求

    /// 发一次请求并等它结束。
    /// - 注意：`onDelta`/`onThinking` 在后台线程回调，视图里必须自己切主线程。
    /// - `context` 非空时按 spec 记一条 UsageRecord（含 content_filter 归因所需的一切）。
    @MainActor
    static func run(spec: AiTaskSpec,
                    messages: [LlmMessage],
                    context: ModelContext? = nil,
                    projectID: UUID? = nil,
                    onDelta: ((String) -> Void)? = nil,
                    onThinking: ((String) -> Void)? = nil) async throws -> AiResult {
        guard let resolved = resolve(slot: spec.slot) else { throw AiError.noCredential }
        let modelName = resolved.model.trimmingCharacters(in: .whitespaces)
        guard !modelName.isEmpty else { throw AiError.emptyModel }

        try acquire()
        defer { release() }

        let collector = AiStreamCollector()
        let once = AiOnceFlag()

        let result: AiResult = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<AiResult, Error>) in
            LlmClient.shared.stream(credential: resolved.credential,
                                    messages: messages,
                                    temperature: spec.temperature,
                                    maxTokens: spec.maxTokens) { ev in
                if !ev.contentDelta.isEmpty {
                    collector.appendContent(ev.contentDelta)
                    onDelta?(ev.contentDelta)
                }
                if !ev.thinkingDelta.isEmpty {
                    collector.appendThinking(ev.thinkingDelta)
                    onThinking?(ev.thinkingDelta)
                }
                guard let fin = ev.finished else { return }
                guard once.claim() else { return }

                let kind = AiFinishKind.classify(fin)
                let usage = ev.usage.map {
                    TokenUsage(input: $0.input, output: $0.output, cached: $0.cached)
                }
                let out = AiResult(text: collector.content.trimmingCharacters(in: .whitespacesAndNewlines),
                                   thinking: collector.thinking,
                                   finish: kind,
                                   rawFinishReason: fin,
                                   usage: usage,
                                   model: modelName,
                                   credentialName: resolved.credential.name)
                if case .error(let msg) = kind {
                    cont.resume(throwing: AiError.server(msg))
                } else {
                    cont.resume(returning: out)
                }
            }
        }

        if let ctx = context, let usage = result.usage {
            UsageService.record(context: ctx,
                                credentialName: result.credentialName,
                                model: result.model,
                                task: spec.taskLabel,
                                stage: spec.stage,
                                chapterIndex: spec.chapterIndex,
                                projectID: projectID,
                                usage: usage)
        }
        return result
    }

    // MARK: JSON 任务（自带重试 nudge）

    /// 跑一个"只输出 JSON"的任务：解析失败时带母版 nudge 重试，最多 spec.jsonRetries 次。
    @MainActor
    static func runJSON(spec: AiTaskSpec,
                        messages: [LlmMessage],
                        context: ModelContext? = nil,
                        projectID: UUID? = nil,
                        onRaw: ((String) -> Void)? = nil) async throws -> (json: [String: Any], result: AiResult) {
        var msgs = messages
        let attempts = max(1, spec.jsonRetries + 1)
        var lastSnippet = ""

        for attempt in 0..<attempts {
            let r = try await run(spec: spec, messages: msgs, context: context, projectID: projectID)
            lastSnippet = String(r.text.prefix(200))
            if let data = PromptBuilder.extractJSONObject(from: r.text),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return (obj, r)
            }
            onRaw?(r.text)
            if attempt < attempts - 1 {
                msgs.append(LlmMessage(role: "assistant", content: r.text))
                msgs.append(LlmMessage(role: "user",
                                       content: "（上一次输出被截断或不是合法 JSON，这次直接给完整 JSON，不要长篇思考。）"))
            }
        }
        throw AiError.badJSON(lastSnippet)
    }
}
