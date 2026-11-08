import Foundation

// MARK: - 凭证档案（对应 Android: ApiCredentialProfile）

struct ApiCredential: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String                 // 凭证名称
    var baseURL: String              // 服务地址（https://api.deepseek.com 等）
    var model: String                // 默认模型
    var keyRef: String { "credential.key.\(id.uuidString)" }

    var apiKey: String {
        get { KeychainStore.load(key: keyRef) ?? "" }
        set {
            if newValue.isEmpty { _ = KeychainStore.delete(key: keyRef) }
            else { _ = KeychainStore.save(key: keyRef, value: newValue) }
        }
    }

    static let deepseek = ApiCredential(name: "DeepSeek 官方", baseURL: "https://api.deepseek.com", model: "deepseek-chat")
    static let openrouter = ApiCredential(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "")
    static var defaults: [ApiCredential] { [.deepseek, .openrouter] }
}

// MARK: - 请求/响应模型（OpenAI 兼容 /chat/completions）

struct LlmMessage: Codable {
    var role: String        // "system" | "user" | "assistant"
    var content: String
}

struct ChatCompletionRequest: Encodable {
    struct StreamOptions: Encodable { var include_usage: Bool = true }
    var model: String
    var messages: [LlmMessage]
    var stream: Bool = true
    var temperature: Double?
    var max_tokens: Int?
    var stream_options: StreamOptions? = nil

    enum CodingKeys: String, CodingKey { case model, messages, stream, temperature, max_tokens, stream_options }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encode(stream, forKey: .stream)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(max_tokens, forKey: .max_tokens)
        if stream { try c.encodeIfPresent(stream_options, forKey: .stream_options) }
    }
}

struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
            var reasoning_content: String?   // DeepSeek / OpenRouter 思考增量
        }
        var delta: Delta?
        var finish_reason: String?
    }
    struct Usage: Decodable {
        struct PromptTokensDetails: Decodable { var cached_tokens: Int? }
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var prompt_tokens_details: PromptTokensDetails?
    }
    var choices: [Choice]?
    var usage: Usage?
}

struct NonStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable { var content: String?; var reasoning_content: String? }
        var message: Msg?
    }
    struct Usage: Decodable {
        struct PromptDetails: Decodable { var cached_tokens: Int? }
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var prompt_tokens_details: PromptDetails?
    }
    var choices: [Choice]?
    var usage: Usage?
}

struct LlmStreamEvent {
    var contentDelta: String = ""
    var thinkingDelta: String = ""
    var finished: String? = nil        // finish_reason
    var usage: (input: Int, output: Int, cached: Int)? = nil
}

enum LlmError: LocalizedError {
    case badURL
    case http(Int, String)
    case cancelled
    case emptyModel
    case streamParse(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务地址无效"
        case .http(let code, let body): return "服务返回 HTTP \(code)\n详情=\(body.prefix(300))"
        case .cancelled: return "任务已停止"
        case .emptyModel: return "模型名未填写：请到「设置 → 凭证管理」编辑凭证填写模型（如 deepseek-chat）"
        case .streamParse(let s): return "流式响应无法解析（服务端可能不支持 stream:true）\n返回片段=\(s)"
        }
    }
}

// MARK: - LLM 网关（对应 Android: OkHttp SSE 流式网关）

final class LlmClient {
    static let shared = LlmClient()

    private var currentTask: Task<Void, Never>?

    /// 流式请求，逐事件回调。返回值用于外部取消。
    @discardableResult
    func stream(
        credential: ApiCredential,
        messages: [LlmMessage],
        temperature: Double? = 1.0,
        maxTokens: Int? = nil,
        onEvent: @escaping (LlmStreamEvent) -> Void
    ) -> Task<Void, Never> {
        let task = Task<Void, Never> {
            do {
                try await perform(credential: credential, messages: messages,
                                  temperature: temperature, maxTokens: maxTokens,
                                  onEvent: onEvent)
            } catch is CancellationError {
                onEvent(LlmStreamEvent(finished: "stopped"))
            } catch {
                onEvent(LlmStreamEvent(finished: "error:\(error.localizedDescription)"))
            }
        }
        currentTask = task
        return task
    }

    func stop() {
        currentTask?.cancel()
    }

    private func perform(
        credential: ApiCredential,
        messages: [LlmMessage],
        temperature: Double?,
        maxTokens: Int?,
        onEvent: @escaping (LlmStreamEvent) -> Void
    ) async throws {
        let model = credential.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw LlmError.emptyModel }
        do {
            try await runOnce(credential: credential, model: model, messages: messages,
                              temperature: temperature, maxTokens: maxTokens,
                              includeStreamOptions: true, onEvent: onEvent)
        } catch LlmError.http(let code, _) where (400...499).contains(code) {
            // 兼容模式重试（对应 Android: 兼容重试）——部分服务不接受 stream_options 字段
            try await runOnce(credential: credential, model: model, messages: messages,
                              temperature: temperature, maxTokens: maxTokens,
                              includeStreamOptions: false, onEvent: onEvent)
        }
    }

    private func runOnce(
        credential: ApiCredential,
        model: String,
        messages: [LlmMessage],
        temperature: Double?,
        maxTokens: Int?,
        includeStreamOptions: Bool,
        onEvent: @escaping (LlmStreamEvent) -> Void
    ) async throws {
        guard let url = URL(string: credential.baseURL.trimmingCharacters(in: .whitespaces)
            .appending("/chat/completions")) else { throw LlmError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")

        var body = ChatCompletionRequest(
            model: model, messages: messages,
            stream: true, temperature: temperature, max_tokens: maxTokens)
        if !includeStreamOptions { body.stream_options = nil }
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw LlmError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            var err = Data()
            for try await b in bytes.prefix(4096) { err.append(b) }
            throw LlmError.http(http.statusCode, String(data: err, encoding: .utf8) ?? "")
        }

        // 按行缓冲解码（保证多字节 UTF-8 中文不被逐字节截断）；同时累计原文用于兼容模式兜底
        var bodyData = Data()
        var lineBytes = [UInt8]()
        var sawDataEvent = false
        var unparsedLines = 0
        var finishedEmitted = false   // finished 事件只允许发一次（下游 withCheckedContinuation 重复 resume 会崩溃）
        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            bodyData.append(byte)
            if byte == 0x0A { // '\n'
                defer { lineBytes.removeAll(keepingCapacity: true) }
                guard let line = String(bytes: lineBytes, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces)
                else { continue }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    if !finishedEmitted { onEvent(LlmStreamEvent(finished: "done")) }
                    return
                }
                // 服务端中途错误帧（内容过滤/额度等）：data: {"error": {...}} —— 不能当普通空块忽略
                if payload.hasPrefix("{"),
                   let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                   obj["error"] != nil {
                    let msg = (obj["error"] as? [String: Any])?["message"] as? String
                        ?? String(payload.prefix(200))
                    onEvent(LlmStreamEvent(finished: "error:服务端中途返回错误：\(msg)"))
                    return
                }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data)
                else { unparsedLines += 1; continue }
                var ev = LlmStreamEvent()
                if let delta = chunk.choices?.first?.delta {
                    ev.contentDelta = delta.content ?? ""
                    ev.thinkingDelta = delta.reasoning_content ?? ""
                }
                ev.finished = chunk.choices?.first?.finish_reason
                if ev.finished != nil { finishedEmitted = true }
                if let u = chunk.usage {
                    ev.usage = (u.prompt_tokens ?? 0, u.completion_tokens ?? 0,
                                u.prompt_tokens_details?.cached_tokens ?? 0)
                }
                if !ev.contentDelta.isEmpty || !ev.thinkingDelta.isEmpty
                    || ev.finished != nil || ev.usage != nil { sawDataEvent = true }
                onEvent(ev)
            } else {
                if byte != 0x0D { // 忽略 '\r'
                    lineBytes.append(byte)
                }
            }
        }

        // 流正常结束：若没解析出任何 SSE 事件——大概率服务端无视 stream:true 回了一份普通 JSON（兼容模式）
        if sawDataEvent {
            if !finishedEmitted { onEvent(LlmStreamEvent(finished: "done")) }
            return
        }
        if let wrap = try? JSONDecoder().decode(NonStreamResponse.self, from: bodyData),
           let msg = wrap.choices?.first?.message {
            let content = msg.content ?? ""
            let reasoning = msg.reasoning_content ?? ""
            if !content.isEmpty || !reasoning.isEmpty {
                var ev = LlmStreamEvent()
                ev.contentDelta = content
                ev.thinkingDelta = reasoning
                if let u = wrap.usage {
                    ev.usage = (u.prompt_tokens ?? 0, u.completion_tokens ?? 0,
                                u.prompt_tokens_details?.cached_tokens ?? 0)
                }
                onEvent(ev)
                onEvent(LlmStreamEvent(finished: "done"))
                return
            }
        }
        let snippet = String(data: bodyData.prefix(300), encoding: .utf8) ?? "（非 UTF-8 文本）"
        let note = unparsedLines > 0 ? "（\(unparsedLines) 行无法按数据块解析）" : ""
        throw LlmError.streamParse("HTTP 200 但没有有效流式数据\(note)。返回片段：\(snippet)")
    }

    /// 非流式测试连接（对应 UI："测试连接"/"实测"）
    static func testConnection(credential: ApiCredential) async throws -> String {
        guard let url = URL(string: credential.baseURL.trimmingCharacters(in: .whitespaces)
            .appending("/chat/completions")) else { throw LlmError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = credential.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw LlmError.emptyModel }
        let body = ChatCompletionRequest(
            model: model,
            messages: [LlmMessage(role: "user", content: "回复一个字：好")],
            stream: false, temperature: 0, max_tokens: 8, stream_options: nil)
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LlmError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            throw LlmError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Wrap: Decodable { struct C: Decodable { struct M: Decodable { var content: String? }; var message: M? }; var choices: [C]? }
        let wrap = try JSONDecoder().decode(Wrap.self, from: data)
        return wrap.choices?.first?.message?.content ?? "连接成功"
    }
}
