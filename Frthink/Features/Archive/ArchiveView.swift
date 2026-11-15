import SwiftUI
import SwiftData

/// 功能区：把原来分散的「人物 / 世界 / 事件 / 文风 / 语料」收进一个页签。
///
/// 术语按「分析动作 → 产物」重新命名，避免旧名混淆：
///   设定（WorldEntry + CorpusEntry）  ← 收集事实
///   角色（CharacterCard）             ← 提取角色
///   剧情（PlotEvent）                 ← 提取剧情
///   文风（WritingRule）               ← 归纳文风
enum ArchivePane: String, CaseIterable, Identifiable {
    case setting, character, plot, style
    var id: String { rawValue }

    var title: String {
        switch self {
        case .setting: return "设定"
        case .character: return "角色"
        case .plot: return "剧情"
        case .style: return "文风"
        }
    }

    var hint: String {
        switch self {
        case .setting: return "世界观与事实：词条按关键词注入，语料是正文里提炼的设定事实"
        case .character: return "出场角色卡：身份、动机、说话方式，注入时按启用状态筛选"
        case .plot: return "剧情节点：起因 / 发展 / 结果，用于前情与伏笔追踪"
        case .style: return "文风规则：句式、对白密度、视角纪律，注入到每次续写"
        }
    }
}

struct ArchiveView: View {
    @Bindable var project: BookProject
    @Binding var requestPane: ArchivePane?

    @Environment(\.modelContext) private var context
    @Query private var allCards: [CharacterCard]
    @Query private var allWorld: [WorldEntry]
    @Query private var allCorpus: [CorpusEntry]
    @Query private var allEvents: [PlotEvent]
    @Query private var allRules: [WritingRule]

    @State private var pane: ArchivePane = .setting
    @State private var query = ""

    @State private var showOrganize = false
    @State private var editingCard: CharacterCard?
    @State private var showNewCard = false

    @State private var editingEntry: WorldEntry?
    @State private var showNewEntry = false
    @State private var showCorpusList = false
    @State private var showCorpusCollect = false

    @State private var editingEvent: PlotEvent?
    @State private var showNewEvent = false
    @State private var showExtract = false

    @State private var showRules = false
    @State private var editingRule: WritingRule?

    // MARK: 数据

    private var cards: [CharacterCard] { allCards.filter { $0.project == project } }
    private var entries: [WorldEntry] { ProjectData.worldEntries(project, context: context) }
    private var corpus: [CorpusEntry] { allCorpus.filter { $0.project == project } }
    private var events: [PlotEvent] { allEvents.filter { $0.project == project } }
    private var rules: [WritingRule] {
        allRules.filter { $0.project == project }
    }

    private func hit(_ s: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return s.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("分区", selection: $pane) {
                ForEach(ArchivePane.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            searchBar
            actionBar
            Divider()
            contentList
        }
        // 编辑器与动作面板
        .sheet(isPresented: $showOrganize) { CharacterOrganizeSheet(project: project) }
        .sheet(item: $editingCard) { c in CardEditorSheet(project: project, card: c) }
        .sheet(isPresented: $showNewCard) { CardEditorSheet(project: project, card: nil) }
        .sheet(item: $editingEntry) { e in WorldEntryEditor(project: project, entry: e) }
        .sheet(isPresented: $showNewEntry) { WorldEntryEditor(project: project, entry: nil) }
        .sheet(isPresented: $showCorpusList) { CorpusListView(project: project) }
        .sheet(isPresented: $showCorpusCollect) { CorpusCollectSheet(project: project) }
        .sheet(item: $editingEvent) { e in EventEditor(project: project, event: e) }
        .sheet(isPresented: $showNewEvent) { EventEditor(project: project, event: nil) }
        .sheet(isPresented: $showExtract) { EventExtractSheet(project: project) }
        .sheet(item: $editingRule) { r in RuleEditSheet(rule: r) }
        .onChange(of: requestPane) { _, newValue in
            if let newValue {
                pane = newValue
                requestPane = nil
            }
        }
        .fullScreenCover(isPresented: $showRules) {
            ModalPage { RulesView(project: project) }
        }
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("搜索\(pane.title)", text: $query)
                .font(.callout)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: 动作条

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(pane.hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Menu {
                switch pane {
                case .setting:
                    Button("收集事实到语料") { showCorpusCollect = true }
                    Button("查看语料库") { showCorpusList = true }
                    Button("新增设定词条") { showNewEntry = true }
                case .character:
                    Button("提取角色（分析锚前正文）") { showOrganize = true }
                    Button("新建角色卡") { showNewCard = true }
                case .plot:
                    Button("提取剧情节点") { showExtract = true }
                    Button("新增剧情节点") { showNewEvent = true }
                case .style:
                    Button("归纳文风规则") { showRules = true }
                }
            } label: {
                Label("动作", systemImage: "wand.and.stars")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: 列表

    @ViewBuilder
    private var contentList: some View {
        List {
            switch pane {
            case .setting: settingRows
            case .character: characterRows
            case .plot: plotRows
            case .style: styleRows
            }
        }
        .listStyle(.plain)
    }

    // MARK: 设定

    @ViewBuilder
    private var settingRows: some View {
        let ws = entries.filter { hit($0.title + $0.keywords + $0.content) }
        let cs = corpus.filter { hit($0.content) }

        Section {
            ForEach(ws) { e in
                LibraryRowView(title: e.title,
                               subtitle: e.keywords.isEmpty ? "常驻注入" : "关键词：\(e.keywords)",
                               detail: e.content,
                               enabled: e.enabled,
                               onToggle: { v in
                                   e.enabled = v
                                   try? context.save()
                               },
                               onEdit: { editingEntry = e })
            }
        } header: {
            Text("设定词条（\(ws.count)）")
        }

        Section {
            ForEach(cs) { t in
                LibraryRowView(title: String(t.content.prefix(18)),
                               subtitle: String(t.content.prefix(60)),
                               detail: t.content,
                               enabled: nil,
                               onToggle: nil,
                               onEdit: nil)
            }
        } header: {
            Text("语料事实（\(cs.count)）")
        }
    }

    // MARK: 角色

    @ViewBuilder
    private var characterRows: some View {
        let list = cards.filter { hit($0.name + $0.identity + $0.personality + $0.speech) }
        Section {
            ForEach(list) { c in
                LibraryRowView(title: c.name,
                               subtitle: [c.identity, c.personality].filter { !$0.isEmpty }.joined(separator: " · "),
                               detail: cardDetail(c),
                               enabled: c.enabled,
                               onToggle: { v in
                                   c.enabled = v
                                   try? context.save()
                               },
                               onEdit: { editingCard = c })
            }
        } header: {
            Text("角色卡（\(list.count)）")
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
        return parts.isEmpty ? "（仅名称）" : parts.joined(separator: "\n")
    }

    // MARK: 剧情

    @ViewBuilder
    private var plotRows: some View {
        let list = events.filter { hit($0.title + $0.cause + $0.development + $0.result) }
        Section {
            ForEach(list) { ev in
                LibraryRowView(title: ev.title,
                               subtitle: ev.cause.isEmpty ? "（无起因）" : "起因：\(ev.cause)",
                               detail: "发展：\(ev.development)\n\n结果：\(ev.result)",
                               enabled: nil,
                               onToggle: nil,
                               onEdit: { editingEvent = ev })
            }
        } header: {
            Text("剧情节点（\(list.count)）")
        }
    }

    // MARK: 文风

    @ViewBuilder
    private var styleRows: some View {
        let list = rules.filter { hit($0.line) }
        Section {
            ForEach(list) { r in
                LibraryRowView(title: r.kind == "style" ? "文风" : r.kind,
                               subtitle: String(r.line.prefix(60)),
                               detail: r.line,
                               enabled: nil,
                               onToggle: nil,
                               onEdit: { editingRule = r })
            }
        } header: {
            Text("文风规则（\(list.count)）")
        }
    }
}

/// 单条文风规则的编辑（RulesView 的归纳是整页功能，这里只改一行）
struct RuleEditSheet: View {
    @Bindable var rule: WritingRule

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("规则内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle("编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        rule.line = text
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onAppear { text = rule.line }
        }
    }
}
