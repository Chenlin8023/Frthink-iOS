import Foundation

/// 内容档案（每本书一份）：把 BookProject 上散落的可选字段收敛成一个可读可写的值类型。
///
/// 设计约束（reports/10 §3.1 / §4.3）：
/// - `contentLevel == nil` 表示"用户还没选过"（首启三选一），与显式选的 `off`（明确不写）区分；
///   运行时默认档取 .medium，但 `levelExplicitlySet == false` 时 UI 必须再问一次。
/// - relDimsJSON 解析失败一律回落内置常规六维，绝不因为坏 JSON 崩流程。
struct ContentPlan {

    // MARK: - 尺度档

    enum Level: String, CaseIterable, Identifiable {
        case off, suggest, medium, explicit, extreme

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "不写"
            case .suggest: return "暗示"
            case .medium: return "中度"
            case .explicit: return "露骨"
            case .extreme: return "极端"
            }
        }

        var detail: String {
            switch self {
            case .off: return "本章不写情色场面，其余文风纪律照常"
            case .suggest: return "只写氛围与后果，不写过程"
            case .medium: return "写过程但不铺细节"
            case .explicit: return "写足场面，动作、对白、反应都给到"
            case .extreme: return "不设上限，按基调与标记写满"
            }
        }

        var isAdult: Bool { self != .off }
    }

    // MARK: - 字段

    var level: Level = .medium
    /// 用户是否显式选过（false 时进制作台要先问一次）
    var levelExplicitlySet: Bool = false
    var cadenceStart: Int = 4
    var cadenceEvery: Int = 2
    var groupScenes: Int = 0
    var tone: String = ""
    var perspective: String = ""
    var targetChapterChars: Int = 4000
    var dims: [ContentKit.RelDim] = ContentKit.vanillaDims
    var dimSet: ContentKit.DimSet = .vanilla
    var rulesOverride: String = ""
    var remakeInstruction: String = ""

    // MARK: - 读写

    /// 从书项目读取（所有字段都可空，任何缺失/坏值都有默认兜底）
    static func load(from project: BookProject) -> ContentPlan {
        var plan = ContentPlan()

        if let raw = project.contentLevel, let lv = Level(rawValue: raw) {
            plan.level = lv
            plan.levelExplicitlySet = true
        } else {
            plan.level = .medium
            plan.levelExplicitlySet = false
        }

        if let s = project.cadenceStart { plan.cadenceStart = min(max(s, 1), 30) }
        if let e = project.cadenceEvery { plan.cadenceEvery = min(max(e, 1), 10) }
        if let g = project.groupScenes { plan.groupScenes = min(max(g, 0), 8) }
        if let tc = project.targetChapterChars { plan.targetChapterChars = min(max(tc, 800), 12000) }
        plan.tone = project.tone ?? ""
        plan.perspective = project.perspective ?? ""
        plan.rulesOverride = project.writerRulesOverride ?? ""
        plan.remakeInstruction = project.remakeInstruction ?? ""

        if let json = project.relDimsJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ContentKit.RelDim].self, from: data),
           !decoded.isEmpty {
            plan.dims = decoded
            plan.dimSet = (decoded.map(\.n) == ContentKit.ntrDims.map(\.n)) ? .ntr : .vanilla
        } else {
            plan.dims = ContentKit.vanillaDims
            plan.dimSet = .vanilla
        }

        // 用户显式选过 off 才算"不写"；没选过按 .medium 运行（UI 会先问）
        return plan
    }

    /// 写回书项目（唯一写入路径；UI 只改 ContentPlan，不直接摸字段）
    func apply(to project: BookProject) {
        project.contentLevel = level.rawValue
        project.cadenceStart = cadenceStart
        project.cadenceEvery = cadenceEvery
        project.groupScenes = groupScenes
        project.tone = tone
        project.perspective = perspective
        project.targetChapterChars = targetChapterChars
        project.writerRulesOverride = rulesOverride
        project.remakeInstruction = remakeInstruction

        if let data = try? JSONEncoder().encode(dims),
           let json = String(data: data, encoding: .utf8) {
            project.relDimsJSON = json
        }
        project.updatedAt = .now
    }

    // MARK: - 派生量

    /// 写手规则（含 18 条 + 基调；level == off 时换开头段）
    var writerRules: String {
        ContentKit.writerRules(perspective: perspective,
                              tone: tone,
                              targetChars: targetChapterChars,
                              level: level.rawValue,
                              override: rulesOverride)
    }

    /// 大纲规划用的节奏段
    func cadencePromptBlock(tagWhitelist: String) -> String {
        ContentKit.cadenceBlock(cadenceStart: cadenceStart,
                                cadenceEvery: cadenceEvery,
                                groupScenes: groupScenes,
                                level: level.rawValue,
                                tagWhitelist: tagWhitelist)
    }

    var summaryLine: String {
        var parts: [String] = []
        parts.append("尺度 \(level.title)")
        parts.append("节奏 \(cadenceStart)/\(cadenceEvery)")
        if groupScenes > 0 { parts.append("群体 \(groupScenes) 场") }
        parts.append("单章 \(targetChapterChars) 字")
        if !tone.isEmpty { parts.append("基调已设") }
        if !rulesOverride.isEmpty { parts.append("规则已覆盖") }
        return parts.joined(separator: " · ")
    }

    /// 状态档提示词里的维度说明行
    var dimLines: String {
        dims.map { "- \($0.n)：\($0.d)" }.joined(separator: "\n")
    }

    /// 状态档 JSON 示例（母版 relExample 的生成方式）
    var relExampleJSON: String {
        let pairs = dims.map { "\(quoted($0.n)): \($0.initial)" }
        return "{" + pairs.joined(separator: ", ") + "}"
    }

    private func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 切维度（保留同名维度的旧值，其余用新维度初值）
    mutating func switchDims(to set: ContentKit.DimSet, keepFrom old: [String: Int]) {
        let newDims = ContentKit.dims(for: set)
        dims = newDims.map { d in
            var copy = d
            if let v = old[d.n] { copy.initial = min(max(v, 0), 100) }
            return copy
        }
        dimSet = set
    }

    /// 应用基调预设（一次写入 tone / cadence / 维度集；opts 由调用方决定是否写进章节 tags）
}
