import Foundation
import SwiftUI
import SwiftData

/// 应用设置（对应 Android: DataStore StoredSettings / AgentSettings）
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    // 凭证
    var credentials: [ApiCredential] {
        didSet { saveCredentials() }
    }
    var activeCredentialId: UUID {
        didSet { UserDefaults.standard.set(activeCredentialId.uuidString, forKey: "active.credential") }
    }

    // 分任务模型（写作/摘要/翻译/整理）
    var writingModel: String { didSet { defaults.set(writingModel, forKey: "model.writing") } }
    var summaryModel: String { didSet { defaults.set(summaryModel, forKey: "model.summary") } }
    var translationModel: String { didSet { defaults.set(translationModel, forKey: "model.translation") } }
    var extractModel: String { didSet { defaults.set(extractModel, forKey: "model.extract") } }

    // 预算与生成参数
    var contextBudget: Int { didSet { defaults.set(contextBudget, forKey: "budget.context") } }        // 正文尾部注入字符数
    var segmentBudget: Int { didSet { defaults.set(segmentBudget, forKey: "budget.segment") } }        // 整理单段字符数
    var temperature: Double { didSet { defaults.set(temperature, forKey: "gen.temperature") } }
    var maxOutputTokens: Int { didSet { defaults.set(maxOutputTokens, forKey: "gen.maxTokens") } }

    // 外观与反馈
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "ui.haptics") } }

    private let defaults = UserDefaults.standard

    init() {
        // @Observable 属性在 init 内不可读访问器（要求 self 完全初始化）——先算局部量，最后统一赋值
        let saved = (try? JSONDecoder().decode([ApiCredential].self,
                    from: defaults.data(forKey: "credentials") ?? Data())) ?? []
        let creds = saved.isEmpty ? ApiCredential.defaults : saved
        let activeId = defaults.string(forKey: "active.credential").flatMap(UUID.init)
            ?? creds.first?.id ?? UUID()
        let wm = defaults.string(forKey: "model.writing") ?? ""
        let sm = defaults.string(forKey: "model.summary") ?? ""
        let tm = defaults.string(forKey: "model.translation") ?? ""
        let em = defaults.string(forKey: "model.extract") ?? ""
        let cb = defaults.object(forKey: "budget.context") as? Int ?? 6000
        let sb = defaults.object(forKey: "budget.segment") as? Int ?? 3000
        let tp = defaults.object(forKey: "gen.temperature") as? Double ?? 1.0
        let mt = defaults.object(forKey: "gen.maxTokens") as? Int ?? 4096
        let hp = defaults.object(forKey: "ui.haptics") as? Bool ?? true

        self.credentials = creds
        self.activeCredentialId = activeId
        self.writingModel = wm
        self.summaryModel = sm
        self.translationModel = tm
        self.extractModel = em
        self.contextBudget = cb
        self.segmentBudget = sb
        self.temperature = tp
        self.maxOutputTokens = mt
        self.hapticsEnabled = hp
    }

    private func saveCredentials() {
        if let data = try? JSONEncoder().encode(credentials) {
            defaults.set(data, forKey: "credentials")
        }
    }

    var activeCredential: ApiCredential? {
        credentials.first { $0.id == activeCredentialId } ?? credentials.first
    }

    func credential(key: UUID) -> ApiCredential? { credentials.first { $0.id == key } }

    /// 任务→模型：未单独配置时回落到写作模型 / 凭证默认模型
    func model(for task: String) -> String {
        let specific: String
        switch task {
        case "summary": specific = summaryModel
        case "translation": specific = translationModel
        case "extract": specific = extractModel
        default: specific = writingModel
        }
        if !specific.isEmpty { return specific }
        return activeCredential?.model ?? ""
    }

    func haptic() {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - 项目关联数据的谓词查询（SwiftData inverse 简化为按谓词取数）

enum ProjectData {
    static func worldEntries(_ p: BookProject, context: ModelContext) -> [WorldEntry] {
        let pred = #Predicate<WorldEntry> { $0.project == nil }
        // nil 与具体项目各取一次：全局条目 + 本书条目
        let global = (try? context.fetch(FetchDescriptor(predicate: pred))) ?? []
        let mine = (try? context.fetch(FetchDescriptor<WorldEntry>()))?.filter { $0.project == p } ?? []
        return global.filter { $0.project == nil } + mine
    }
    static func corpusEntries(_ p: BookProject, context: ModelContext) -> [CorpusEntry] {
        let mine = (try? context.fetch(FetchDescriptor<CorpusEntry>()))?.filter { $0.project == p } ?? []
        return mine
    }
    static func globalRules(context: ModelContext) -> [WritingRule] {
        (try? context.fetch(FetchDescriptor<WritingRule>()))?.filter { $0.project == nil && $0.kind == "style" } ?? []
    }
}

// MARK: - 存档信封（对应 Android: FrthinkArchiveEnvelope / ProjectArchivePayload）

struct FrthinkArchive: Codable {
    var format: String = "frthink-archive"
    var formatVersion: Int = 1
    var exportedAt: Date = .now
    var books: [BookArchive]
}

struct BookArchive: Codable {
    var title: String
    var synopsis: String
    var genre: String
    var body: String
    var anchorOffset: Int?
    var cards: [CardDTO]
    var world: [WorldDTO]
    var corpus: [String]
    var rules: [RuleDTO]
    var events: [EventDTO]
    var messages: [MessageDTO]

    struct CardDTO: Codable { var name, aliases, identity, goals, personality, speech, boundaries, memories, attitudes, groupName: String; var enabled: Bool }
    struct WorldDTO: Codable { var title, keywords, content: String; var enabled: Bool }
    struct RuleDTO: Codable { var kind, line: String }
    struct EventDTO: Codable { var title, cause, development, result: String }
    struct MessageDTO: Codable { var role, content, thinking: String; var createdAt: Date }
}

enum ArchiveService {
    static func export(project: BookProject, context: ModelContext) -> Data {
        let archive = FrthinkArchive(books: [makeBookArchive(project, context: context)])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        return (try? enc.encode(archive)) ?? Data()
    }

    static func exportAll(projects: [BookProject], context: ModelContext) -> Data {
        let archive = FrthinkArchive(books: projects.map { makeBookArchive($0, context: context) })
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(archive)) ?? Data()
    }

    private static func makeBookArchive(_ p: BookProject, context: ModelContext) -> BookArchive {
        BookArchive(
            title: p.title, synopsis: p.synopsis, genre: p.genre, body: p.body,
            anchorOffset: p.anchorOffset,
            cards: p.characterCards.map {
                .init(name: $0.name, aliases: $0.aliases, identity: $0.identity, goals: $0.goals,
                      personality: $0.personality, speech: $0.speech, boundaries: $0.boundaries,
                      memories: $0.memories, attitudes: $0.attitudes, groupName: $0.groupName, enabled: $0.enabled)
            },
            world: ProjectData.worldEntries(p, context: context).map {
                .init(title: $0.title, keywords: $0.keywords, content: $0.content, enabled: $0.enabled)
            },
            corpus: ProjectData.corpusEntries(p, context: context).map(\.content),
            rules: (try? context.fetch(FetchDescriptor<WritingRule>()))?
                .filter { $0.project == p }.map { .init(kind: $0.kind, line: $0.line) } ?? [],
            events: p.events.map { .init(title: $0.title, cause: $0.cause, development: $0.development, result: $0.result) },
            messages: p.messages.sorted { $0.createdAt < $1.createdAt }.map {
                .init(role: $0.role, content: $0.content, thinking: $0.thinking, createdAt: $0.createdAt)
            })
    }

    static func importArchive(_ data: Data, into context: ModelContext) -> Int {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let archive = try? dec.decode(FrthinkArchive.self, from: data) else { return 0 }
        for b in archive.books {
            let p = BookProject(title: b.title, synopsis: b.synopsis, genre: b.genre)
            p.body = b.body
            p.anchorOffset = b.anchorOffset
            context.insert(p)
            for c in b.cards {
                let card = CharacterCard(project: p, name: c.name)
                card.aliases = c.aliases; card.identity = c.identity; card.goals = c.goals
                card.personality = c.personality; card.speech = c.speech; card.boundaries = c.boundaries
                card.memories = c.memories; card.attitudes = c.attitudes; card.groupName = c.groupName
                card.enabled = c.enabled
                context.insert(card)
            }
            for w in b.world {
                let e = WorldEntry(project: p, title: w.title, keywords: w.keywords, content: w.content)
                e.enabled = w.enabled
                context.insert(e)
            }
            for t in b.corpus { context.insert(CorpusEntry(project: p, content: t)) }
            for r in b.rules { context.insert(WritingRule(project: p, kind: r.kind, line: r.line)) }
            for e in b.events {
                let ev = PlotEvent(project: p, title: e.title)
                ev.cause = e.cause; ev.development = e.development; ev.result = e.result
                context.insert(ev)
            }
            for m in b.messages { context.insert(ChatMessage(project: p, role: m.role, content: m.content)) }
        }
        try? context.save()
        return archive.books.count
    }
}
