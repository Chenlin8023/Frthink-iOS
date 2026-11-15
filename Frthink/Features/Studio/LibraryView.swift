import SwiftUI
import SwiftData

/// 资料中心：把散在人物 / 世界 / 事件三页的分析产物，按「世界书」的方式统一查看。
///
/// 与酒馆世界书对齐的几点：分组折叠、条数徽标、搜索、逐条启用开关、点开看全文。
/// 编辑仍回到各自的页面（人物卡编辑器 / 词条编辑器），避免同一份数据两处可改。
struct LibraryView: View {
    @Bindable var project: BookProject

    @Environment(\.modelContext) private var context
    @Query private var allCards: [CharacterCard]
    @Query private var allWorld: [WorldEntry]
    @Query private var allCorpus: [CorpusEntry]
    @Query private var allEvents: [PlotEvent]
    @Query private var allRules: [WritingRule]

    @State private var query = ""
    @State private var showCards = true
    @State private var showSetting = true
    @State private var showEvents = false
    @State private var showRules = false

    // MARK: 数据

    private var cards: [CharacterCard] {
        allCards.filter { $0.project == project }
    }
    private var worldEntries: [WorldEntry] {
        ProjectData.worldEntries(project, context: context)
    }
    private var corpus: [CorpusEntry] {
        allCorpus.filter { $0.project == project }
    }
    private var events: [PlotEvent] {
        allEvents.filter { $0.project == project }
    }
    private var rules: [WritingRule] {
        allRules.filter { $0.project == project || $0.kind == "style" && $0.project == nil }
    }

    private func hit(_ text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return text.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        List {
            headerSection
            cardsSection
            settingSection
            eventsSection
            rulesSection
        }
        .navigationTitle("资料中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 头部

    private var headerSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("搜索条目", text: $query)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain)
                }
            }
            LabeledContent("本锚注入预估",
                           value: "人物 \(cards.filter(\.enabled).count) · 设定 \(corpus.count + worldEntries.filter(\.enabled).count) · 尾部 \(SettingsStore.shared.contextBudget) 字")
                .font(.caption)
        } footer: {
            Text("这里只做查看与开关；改内容请回人物 / 世界 / 事件页，避免两处都能编辑。")
                .font(.caption2)
        }
    }

    // MARK: 人物

    @ViewBuilder
    private var cardsSection: some View {
        let list = cards.filter { hit($0.name + $0.identity + $0.personality) }
        if !list.isEmpty {
            Section {
                if showCards {
                    ForEach(list) { c in
                        LibraryRowView(title: c.name,
                                       subtitle: [c.identity, c.personality].filter { !$0.isEmpty }.joined(separator: " · "),
                                       detail: cardDetail(c),
                                       enabled: c.enabled) { v in
                            c.enabled = v
                            try? context.save()
                        }
                    }
                }
            } header: {
                Button {
                    showCards.toggle()
                } label: {
                    HStack {
                        Text("人物卡（\(list.count)）")
                        Spacer()
                        Image(systemName: showCards ? "chevron.down" : "chevron.right").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cardDetail(_ c: CharacterCard) -> String {
        var parts: [String] = []
        if !c.aliases.isEmpty { parts.append("别称：\(c.aliases)") }
        if !c.goals.isEmpty { parts.append("动机：\(c.goals)") }
        if !c.speech.isEmpty { parts.append("说话方式：\(c.speech)") }
        if !c.memories.isEmpty { parts.append("记忆：\(c.memories)") }
        if !c.attitudes.isEmpty { parts.append("态度：\(c.attitudes)") }
        if !c.boundaries.isEmpty { parts.append("边界：\(c.boundaries)") }
        return parts.isEmpty ? "（没有更多字段）" : parts.joined(separator: "\n")
    }

    // MARK: 设定

    @ViewBuilder
    private var settingSection: some View {
        let entries = worldEntries.filter { hit($0.title + $0.keywords + $0.content) }
        let corpusHits = corpus.filter { hit($0.content) }
        if !entries.isEmpty || !corpusHits.isEmpty {
            Section {
                if showSetting {
                    ForEach(entries) { e in
                        LibraryRowView(title: e.title,
                                       subtitle: e.keywords.isEmpty ? "常驻" : "关键词：\(e.keywords)",
                                       detail: e.content,
                                       enabled: e.enabled) { v in
                            e.enabled = v
                            try? context.save()
                        }
                    }
                    ForEach(corpusHits) { t in
                        LibraryRowView(title: "语料",
                                       subtitle: String(t.content.prefix(40)),
                                       detail: t.content,
                                       enabled: nil,
                                       onToggle: nil)
                    }
                }
            } header: {
                Button {
                    showSetting.toggle()
                } label: {
                    HStack {
                        Text("世界书 / 设定（\(entries.count) 词条 · \(corpusHits.count) 语料）")
                        Spacer()
                        Image(systemName: showSetting ? "chevron.down" : "chevron.right").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 事件

    @ViewBuilder
    private var eventsSection: some View {
        let list = events.filter { hit($0.title + $0.cause + $0.development + $0.result) }
        if !list.isEmpty {
            Section {
                if showEvents {
                    ForEach(list) { ev in
                        LibraryRowView(title: ev.title,
                                       subtitle: "起因：\(ev.cause)",
                                       detail: "发展：\(ev.development)\n\n结果：\(ev.result)",
                                       enabled: nil,
                                       onToggle: nil)
                    }
                }
            } header: {
                Button {
                    showEvents.toggle()
                } label: {
                    HStack {
                        Text("剧情事件（\(list.count)）")
                        Spacer()
                        Image(systemName: showEvents ? "chevron.down" : "chevron.right").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 规则

    @ViewBuilder
    private var rulesSection: some View {
        let list = rules.filter { hit($0.line) }
        if !list.isEmpty {
            Section {
                if showRules {
                    ForEach(list) { r in
                        LibraryRowView(title: r.kind == "style" ? "文风" : r.kind,
                                       subtitle: String(r.line.prefix(48)),
                                       detail: r.line,
                                       enabled: nil,
                                       onToggle: nil)
                    }
                }
            } header: {
                Button {
                    showRules.toggle()
                } label: {
                    HStack {
                        Text("文风规则（\(list.count)）")
                        Spacer()
                        Image(systemName: showRules ? "chevron.down" : "chevron.right").font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 世界书式的一行：标题 + 副标题 + 可选开关；点一下展开全文。
struct LibraryRowView: View {
    let title: String
    let subtitle: String
    let detail: String
    var enabled: Bool?
    var onToggle: ((Bool) -> Void)?
    var onEdit: (() -> Void)? = nil

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.footnote).lineLimit(1)
                Spacer()
                if let enabled, let onToggle {
                    Toggle("", isOn: Binding(get: { enabled }, set: { onToggle($0) }))
                        .labelsHidden()
                }
                if let onEdit {
                    Button { onEdit() } label: {
                        Image(systemName: "pencil").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(open ? 6 : 2)
            }
            if open {
                Text(detail)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
    }
}
