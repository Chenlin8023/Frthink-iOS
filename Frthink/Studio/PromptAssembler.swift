import Foundation
import SwiftData

/// 按「提示词块」渲染续写请求（酒馆 Prompt Manager 的渲染端）。
///
/// 行为对齐：默认块顺序渲染出来的 system/user，与 v1.9 `PromptBuilder.compileContinuation`
/// 的拼装顺序一致（规则 → 基调 → 设定 → 人物 → 前情 → 要点 → 伏笔 → 意见；user 段尾部原文 → 本轮指令 → 收尾）。
/// 只有在用户改过块（PromptBlockStore.hasCustom）时才走这里，未改动时仍走原函数，保证默认行为不变。
enum PromptAssembler {

    struct Vars {
        var tone = ""
        var setting = ""
        var cards = ""
        var cardsMinor = ""
        var stateL1 = ""
        var stateL2 = ""
        var outline = ""
        var threads = ""
        var marks = ""
        var tail = ""
        var instruction = ""
        var perspective = ""
        var targetChars = ""

        func value(_ name: String) -> String {
            switch name {
            case "tone": return tone
            case "setting": return setting
            case "cards": return cards
            case "cardsMinor": return cardsMinor
            case "stateL1": return stateL1
            case "stateL2": return stateL2
            case "outline": return outline
            case "threads": return threads
            case "marks": return marks
            case "tail": return tail
            case "instruction": return instruction
            case "perspective": return perspective
            case "targetChars": return targetChars
            default: return ""
            }
        }
    }

    // MARK: 组装变量

    static func vars(project: BookProject,
                     context: ModelContext,
                     instruction: String,
                     cardLimit: Int = 8,
                     useCards: Bool = true,
                     useWorld: Bool = true,
                     useCorpus: Bool = true) -> Vars {
        var v = Vars()
        let plan = ContentPlan.load(from: project)

        // 基调（含尺度档，让模型知道这场戏写到什么程度）
        var toneParts: [String] = []
        if !plan.tone.isEmpty { toneParts.append(plan.tone) }
        if plan.level != .off {
            toneParts.append("尺度档：\(plan.level.title)（\(plan.level.detail)）")
        }
        v.tone = toneParts.joined(separator: "\n")

        // 锚前尾部（学习用）
        let anchor = AnalysisScope.anchor(of: project)
        let tailChars = max(500, SettingsStore.shared.contextBudget)
        let start = max(0, anchor - tailChars)
        v.tail = TextSurgery.slice(project.body, start: start, end: anchor)

        // 设定：语料 + 世界书关键词命中
        var settingParts: [String] = []
        if useCorpus {
            let corpus = ProjectData.corpusEntries(project, context: context)
            if !corpus.isEmpty {
                settingParts.append(corpus.prefix(20).map { "- \($0.content)" }.joined(separator: "\n"))
            }
        }
        if useWorld {
            let entries = ProjectData.worldEntries(project, context: context)
            let hits = PromptBuilder.matchedWorldEntries(entries: entries, window: v.tail)
            if !hits.isEmpty {
                settingParts.append(hits.map { "【\($0.title)】\($0.content)" }.joined(separator: "\n"))
            }
        }
        v.setting = settingParts.joined(separator: "\n\n")

        // 人物卡
        if useCards {
            let active = project.characterCards.filter(\.enabled).prefix(cardLimit)
            v.cards = active.map { c -> String in
                var s = "【\(c.name)】"
                if !c.aliases.isEmpty { s += "（别称：\(c.aliases)）" }
                if !c.identity.isEmpty { s += " 身份：\(c.identity)。" }
                if !c.goals.isEmpty { s += " 动机：\(c.goals)。" }
                if !c.personality.isEmpty { s += " 性格：\(c.personality)。" }
                if !c.speech.isEmpty { s += " 说话方式：\(c.speech)。" }
                if !c.memories.isEmpty { s += " 记忆：\(c.memories)。" }
                return s
            }.joined(separator: "\n")
        }

        v.instruction = instruction
        v.perspective = plan.perspective
        v.targetChars = "\(max(800, plan.targetChapterChars - 500))-\(plan.targetChapterChars + 500)"
        return v
    }

    // MARK: 渲染

    /// 渲染一个任务。返回 Compiled（messages + 注入统计），与 PromptBuilder.Compiled 同构。
    static func compose(project: BookProject,
                        context: ModelContext,
                        instruction: String,
                        blocks: [PromptBlock],
                        vars v: Vars) -> PromptBuilder.Compiled {
        var systemParts: [String] = []
        var userParts: [String] = []
        var worldHitCount = 0
        var cardCount = 0

        for block in blocks where block.enabled {
            if block.injection == "never" { continue }
            if block.injection.hasPrefix("ifHas:") {
                let name = String(block.injection.dropFirst("ifHas:".count))
                if v.value(name).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            }
            var text = render(block.body, vars: v)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if block.role == "user" {
                userParts.append(text)
            } else {
                systemParts.append(text)
            }
            if block.key == "setting" { worldHitCount = countLines(v.setting) }
            if block.key == "cards" { cardCount = countLines(v.cards) }
        }

        var system = systemParts.joined(separator: "\n\n")
        system = PromptBuilder.withGlobalPreset(system)
        let user = userParts.joined(separator: "\n\n")

        return PromptBuilder.Compiled(
            messages: [LlmMessage(role: "system", content: system),
                       LlmMessage(role: "user", content: user)],
            injectedWorld: worldHitCount > 0 ? Array(repeating: "命中", count: worldHitCount) : [],
            injectedCards: cardCount > 0 ? Array(repeating: "卡", count: cardCount) : [],
            tailLength: v.tail.count)
    }

    /// {{var}} 替换（未识别的变量替换成空串，不报错）
    static func render(_ template: String, vars v: Vars) -> String {
        var out = template
        for name in PromptBlockStore.availableVars {
            out = out.replacingOccurrences(of: "{{\(name)}}", with: v.value(name))
        }
        // 兜底：清掉残留的 {{...}}
        if let regex = try? NSRegularExpression(pattern: "\\{\\{[a-zA-Z0-9_]+\\}\\}") {
            out = regex.stringByReplacingMatches(in: out,
                                                 range: NSRange(location: 0, length: (out as NSString).length),
                                                 withTemplate: "")
        }
        return out
    }

    private static func countLines(_ s: String) -> Int {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return trimmed.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}
