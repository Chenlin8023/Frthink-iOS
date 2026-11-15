import Foundation
import Observation

/// 续写草稿的跨视图存储（按 project.id 分桶）。
///
/// 存在的理由：v1.9 把「正在生成 / 已生成 / 错误」放在 `ContinuationSheet` 的 `@State` 里，
/// 面板一重建（关闭重开、旋转、父视图刷新）内容就没了 —— 违反「半截内容必须保留」。
/// 现在结果活在这里，只有显式「采纳 / 放弃」才清。
@Observable
final class ContinuationStore {
    static let shared = ContinuationStore()

    struct Draft {
        var text: String = ""
        var thinking: String = ""
        var running: Bool = false
        var error: String? = nil
        var instruction: String = ""
        var finishReason: String = ""
        var startedAt: Date? = nil
        var finishedAt: Date? = nil
        // 用户在面板里改过的提示词（关闭重开后要保留，否则每次都要重编）
        var sysText: String = ""
        var userText: String = ""

        var isEmpty: Bool { text.isEmpty && thinking.isEmpty && error == nil }
        var hasResult: Bool { !text.isEmpty }
    }

    private var drafts: [UUID: Draft] = [:]

    func draft(for id: UUID) -> Draft {
        drafts[id] ?? Draft()
    }

    // MARK: 生命周期

    func begin(_ id: UUID, instruction: String) {
        var d = drafts[id] ?? Draft()
        d.text = ""
        d.thinking = ""
        d.error = nil
        d.running = true
        d.instruction = instruction
        d.finishReason = ""
        d.startedAt = .now
        d.finishedAt = nil
        drafts[id] = d
    }

    func appendContent(_ id: UUID, _ chunk: String) {
        var d = drafts[id] ?? Draft()
        d.text += chunk
        drafts[id] = d
    }

    func appendThinking(_ id: UUID, _ chunk: String) {
        var d = drafts[id] ?? Draft()
        d.thinking += chunk
        drafts[id] = d
    }

    func finish(_ id: UUID, reason: String) {
        var d = drafts[id] ?? Draft()
        d.running = false
        d.finishReason = reason
        d.finishedAt = .now
        if reason.hasPrefix("error:") {
            d.error = String(reason.dropFirst("error:".count))
        }
        drafts[id] = d
    }

    func setError(_ id: UUID, _ message: String) {
        var d = drafts[id] ?? Draft()
        d.running = false
        d.error = message
        d.finishedAt = .now
        drafts[id] = d
    }

    func discard(_ id: UUID) {
        drafts[id] = Draft()
    }

    /// 只清错误，保留正文（重试前用）
    func clearError(_ id: UUID) {
        var d = drafts[id] ?? Draft()
        d.error = nil
        drafts[id] = d
    }

    /// 记住用户改过的提示词（面板重建/关闭重开后仍生效）
    func setPrompts(_ id: UUID, sys: String, user: String) {
        var d = drafts[id] ?? Draft()
        d.sysText = sys
        d.userText = user
        drafts[id] = d
    }

    /// 重建默认提示词时清掉用户覆盖
    func resetPrompts(_ id: UUID) {
        var d = drafts[id] ?? Draft()
        d.sysText = ""
        d.userText = ""
        drafts[id] = d
    }
}
