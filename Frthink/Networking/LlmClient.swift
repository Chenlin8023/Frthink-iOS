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

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务地址无效"
        case .http(let code, let body): return "服务返回 HTTP \(code)\n详情=\(body.prefix(300))"
        case .cancelled: return "任务已停止"
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
        guard let url = URL(string: credential.baseURL.trimmingCharacters(in: .whitespaces)
            .appending("/chat/completions")) else { throw LlmError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")

        let body = ChatCompletionRequest(
            model: credential.model, messages: messages,
            stream: true, temperature: temperature, max_tokens: maxTokens)
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw LlmError.badURL }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await b in bytes { body.append(b) }
            throw LlmError.http(http.statusCode, String(data: body, encoding: .utf8) ?? "")
        }

        // 按行缓冲解码（保证多字节 UTF-8 中文不被逐字节截断）
        var lineBytes = [UInt8]()
        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            if byte == 0x0A { // '\n'
                defer { lineBytes.removeAll(keepingCapacity: true) }
                guard let line = String(bytes: lineBytes, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces)
                else { continue }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    onEvent(LlmStreamEvent(finished: "done"))
                    return
                }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: data)
                else { continue }
                var ev = LlmStreamEvent()
                if let delta = chunk.choices?.first?.delta {
                    ev.contentDelta = delta.content ?? ""
                    ev.thinkingDelta = delta.reasoning_content ?? ""
                }
                ev.finished = chunk.choices?.first?.finish_reason
                if let u = chunk.usage {
                    ev.usage = (u.prompt_tokens ?? 0, u.completion_tokens ?? 0,
                                u.prompt_tokens_details?.cached_tokens ?? 0)
                }
                onEvent(ev)
            } else {
                if byte != 0x0D { // 忽略 '\r'
                    lineBytes.append(byte)
                }
            }
        }
        onEvent(LlmStreamEvent(finished: "done"))
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
        let body = ChatCompletionRequest(
            model: credential.model.isEmpty ? "gpt-4o-mini" : credential.model,
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
