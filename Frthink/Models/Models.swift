import Foundation
import SwiftData

// MARK: - 书项目（对应 Android: projects 表）

@Model
final class BookProject {
    @Attribute(.unique) var id: UUID
    var title: String
    var synopsis: String            // 剧情梗概
    var body: String                // 书稿正文（Markdown 纯文本）
    var coverColorSeed: Int         // 封面配色索引（原应用为图片，iOS 版用配色封面）
    var createdAt: Date
    var updatedAt: Date
    var revision: Int
    var branchRootId: UUID?         // 分支来源（nil = 主干）
    var trashedAt: Date?            // 回收站
    var anchorOffset: Int?          // 续写锚（正文中的字符偏移）
    var bookmarkOffset: Int?        // 书签
    var genre: String               // 本书类型

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.project)
    var messages: [ChatMessage]

    @Relationship(deleteRule: .cascade, inverse: \CharacterCard.project)
    var characterCards: [CharacterCard]

    @Relationship(deleteRule: .cascade, inverse: \PlotEvent.project)
    var events: [PlotEvent]

    @Relationship(deleteRule: .cascade, inverse: \BodySnapshot.project)
    var snapshots: [BodySnapshot]

    init(title: String, synopsis: String = "", genre: String = "") {
        self.id = UUID()
        self.title = title
        self.synopsis = synopsis
        self.body = ""
        self.coverColorSeed = Int.random(in: 0...9)
        self.createdAt = .now
        self.updatedAt = .now
        self.revision = 0
        self.genre = genre
        self.messages = []
        self.characterCards = []
        self.events = []
        self.snapshots = []
    }

    var wordCount: Int { body.count }
    var isTrashed: Bool { trashedAt != nil }
}

// MARK: - 聊天气泡（对应 Android: ChatMessage / ChatMessageVersion）

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var project: BookProject?
    var role: String                // "user" | "assistant"
    var content: String
    var thinking: String            // 思考块（reasoning）
    var createdAt: Date
    var versions: [String]          // 历史版本（保留旧版本）
    var versionIndex: Int           // 当前展示的版本
    var finishReason: String
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int

    init(project: BookProject?, role: String, content: String) {
        self.id = UUID()
        self.project = project
        self.role = role
        self.content = content
        self.thinking = ""
        self.createdAt = .now
        self.versions = []
        self.versionIndex = 0
        self.finishReason = ""
        self.inputTokens = 0
        self.outputTokens = 0
        self.cachedTokens = 0
    }
}

// MARK: - 人物卡（对应 Android: CharacterCard / CharacterMemory）

@Model
final class CharacterCard {
    @Attribute(.unique) var id: UUID
    var project: BookProject?       // nil = 全局共享（宇宙）
    var name: String
    var aliases: String             // 别称/称谓（顿号分隔）
    var identity: String            // 身份与处境
    var goals: String               // 目标与动机
    var personality: String         // 性格
    var speech: String              // 说话方式
    var boundaries: String          // 边界与未知
    var memories: String            // 记忆（仅角色已知）
    var attitudes: String           // 对认识对象的态度
    var groupName: String           // 编组
    var enabled: Bool               // 注入开关
    var createdAt: Date
    var updatedAt: Date

    init(project: BookProject?, name: String) {
        self.id = UUID()
        self.project = project
        self.name = name
        self.aliases = ""
        self.identity = ""
        self.goals = ""
        self.personality = ""
        self.speech = ""
        self.boundaries = ""
        self.memories = ""
        self.attitudes = ""
        self.groupName = ""
        self.enabled = true
        self.createdAt = .now
        self.updatedAt = .now
    }
}

// MARK: - 世界书词条（对应 Android: CorpusEntry / 世界书）

@Model
final class WorldEntry {
    @Attribute(.unique) var id: UUID
    var project: BookProject?       // nil = 全局
    var title: String               // 词条标题
    var keywords: String            // 触发关键词（顿号分隔，空=常驻）
    var content: String             // 词条内容
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(project: BookProject?, title: String, keywords: String = "", content: String = "") {
        self.id = UUID()
        self.project = project
        self.title = title
        self.keywords = keywords
        self.content = content
        self.enabled = true
        self.createdAt = .now
        self.updatedAt = .now
    }
}

// MARK: - 语料条目（对应 Android: CorpusExtraction / 语料收集）

@Model
final class CorpusEntry {
    @Attribute(.unique) var id: UUID
    var project: BookProject?
    var content: String
    var sourceRange: String         // 来源（字符范围说明）
    var createdAt: Date

    init(project: BookProject?, content: String, sourceRange: String = "") {
        self.id = UUID()
        self.project = project
        self.content = content
        self.sourceRange = sourceRange
        self.createdAt = .now
    }
}

// MARK: - 写作规则（长期规则 / 味审查规则）

@Model
final class WritingRule {
    @Attribute(.unique) var id: UUID
    var project: BookProject?       // nil = 全局规则
    var kind: String                // "style" 长期规则 | "review" 味审查规则 | "global" 全局要求
    var line: String
    var createdAt: Date

    init(project: BookProject?, kind: String, line: String) {
        self.id = UUID()
        self.project = project
        self.kind = kind
        self.line = line
        self.createdAt = .now
    }
}

// MARK: - 剧情事件卡（对应 Android: PlotEventCard）

@Model
final class PlotEvent {
    @Attribute(.unique) var id: UUID
    var project: BookProject?
    var title: String
    var cause: String               // 起因
    var development: String         // 发展
    var result: String              // 结果
    var createdAt: Date

    init(project: BookProject?, title: String) {
        self.id = UUID()
        self.project = project
        self.title = title
        self.cause = ""
        self.development = ""
        self.result = ""
        self.createdAt = .now
    }
}

// MARK: - 正文快照（对应 Android: project_snapshots / ChatMessageVersion）

@Model
final class BodySnapshot {
    @Attribute(.unique) var id: UUID
    var project: BookProject?
    var label: String
    var body: String
    var createdAt: Date

    init(project: BookProject?, label: String, body: String) {
        self.id = UUID()
        self.project = project
        self.label = label
        self.body = body
        self.createdAt = .now
    }
}

// MARK: - 用量记录（对应 Android: 消耗分析）

@Model
final class UsageRecord {
    @Attribute(.unique) var id: UUID
    var credentialName: String
    var model: String
    var task: String                // 写作/摘要/翻译/整理
    var inputTokens: Int
    var outputTokens: Int
    var cachedTokens: Int
    var createdAt: Date

    init(credentialName: String, model: String, task: String,
         inputTokens: Int, outputTokens: Int, cachedTokens: Int) {
        self.id = UUID()
        self.credentialName = credentialName
        self.model = model
        self.task = task
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.createdAt = .now
    }
}
