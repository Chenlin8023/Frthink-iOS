import SwiftUI
import SwiftData

/// 人物卡库（对应 Android: CharacterLibrary / 编组 / 人物整理增量提取）
/// 注意：导航栏按钮（✨ 整理 / ＋ 新建）由 ProjectWorkspaceView 统一声明（iOS 17 子视图导航栏项会被丢弃）
struct CharacterCardsView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Binding var organizeSheet: Bool
    @Binding var newCardRequest: Bool
    @State private var showEditor = false
    @State private var editingCard: CharacterCard?

    private var groups: [String: [CharacterCard]] {
        Dictionary(grouping: project.characterCards) { $0.groupName.isEmpty ? "未分组" : $0.groupName }
    }

    var body: some View {
        List {
            if project.characterCards.isEmpty {
                ContentUnavailableView("暂无人物卡", systemImage: "person.2",
                                       description: Text("右上角 ✨ = AI 从正文自动提取人物（推荐）\n右上角 + = 手动新建"))
            }
            if project.body.isEmpty {
                Section { EmptyBodyHint() }
            }
            ForEach(groups.keys.sorted(), id: \.self) { g in
                Section(g) {
                    ForEach(groups[g] ?? []) { card in
                        CardRow(card: card) {
                            editingCard = card
                            showEditor = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            CardEditorSheet(project: project, card: editingCard)
        }
        .sheet(isPresented: $organizeSheet) {
            CharacterOrganizeSheet(project: project)
        }
        .sheet(isPresented: $newCardRequest) {
            CardEditorSheet(project: project, card: nil)
        }
    }
}

struct CardRow: View {
    @Bindable var card: CharacterCard
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(card.name).font(.headline)
                    if !card.aliases.isEmpty {
                        Text(card.aliases).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !card.identity.isEmpty { Text(card.identity).font(.caption).lineLimit(2) }
                if !card.personality.isEmpty { Text("性格：\(card.personality)").font(.caption).lineLimit(2) }
            }
            Spacer()
            Toggle("", isOn: $card.enabled).labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }
}

/// 人物卡编辑
struct CardEditorSheet: View {
    let project: BookProject
    var card: CharacterCard?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliases = ""
    @State private var identity = ""
    @State private var goals = ""
    @State private var personality = ""
    @State private var speech = ""
    @State private var boundaries = ""
    @State private var memories = ""
    @State private var attitudes = ""
    @State private var groupName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    TextField("规范姓名", text: $name)
                    TextField("别称（顿号分隔）", text: $aliases)
                    TextField("编组（可选）", text: $groupName)
                }
                Section("设定") {
                    TextField("身份与处境", text: $identity, axis: .vertical)
                    TextField("目标与动机", text: $goals, axis: .vertical)
                    TextField("性格", text: $personality, axis: .vertical)
                    TextField("说话方式", text: $speech, axis: .vertical)
                }
                Section("深层") {
                    TextField("边界与未知", text: $boundaries, axis: .vertical)
                    TextField("记忆（仅角色已知）", text: $memories, axis: .vertical)
                    TextField("对认识对象的态度", text: $attitudes, axis: .vertical)
                }
            }
            .navigationTitle(card == nil ? "新建人物卡" : "编辑人物卡")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let card {
                            card.name = name; card.aliases = aliases; card.identity = identity
                            card.goals = goals; card.personality = personality; card.speech = speech
                            card.boundaries = boundaries; card.memories = memories
                            card.attitudes = attitudes; card.groupName = groupName
                            card.updatedAt = .now
                        } else {
                            let c = CharacterCard(project: project, name: name.isEmpty ? "未命名" : name)
                            c.aliases = aliases; c.identity = identity; c.goals = goals
                            c.personality = personality; c.speech = speech; c.boundaries = boundaries
                            c.memories = memories; c.attitudes = attitudes; c.groupName = groupName
                            context.insert(c)
                        }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let c = card else { return }
        name = c.name; aliases = c.aliases; identity = c.identity; goals = c.goals
        personality = c.personality; speech = c.speech; boundaries = c.boundaries
        memories = c.memories; attitudes = c.attitudes; groupName = c.groupName
    }
}

/// 人物整理（对应 Android: 增量模式分段提取人物事实）
struct CharacterOrganizeSheet: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var running = false
    @State private var progress = ""
    @State private var processed = 0
    @State private var newCount = 0
    @State private var task: Task<Void, Never>?
    @State private var log: [String] = []
    @State private var showSys = ""
    @State private var showUser = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                AnalysisScopeHeader(project: project) { refreshTemplate() }
                if project.body.isEmpty {
                    EmptyBodyHint()
                }
                HStack {
                    if running {
                        ProgressView().padding(.trailing, 4)
                        Text(progress)
                    } else {
                        Text(processed == 0 ? "将把锚前正文分段整理为人物卡（增量模式，只增不减）"
                             : "已处理 \(processed) 段，新建 \(newCount) 张人物卡")
                    }
                    Spacer()
                    if running {
                        Button("停止", role: .destructive) { task?.cancel() }
                    } else {
                        Button("开始整理") { run() }.buttonStyle(.borderedProminent)
                            .disabled(project.body.isEmpty)
                    }
                }
                if !log.isEmpty {
                    List(log.reversed(), id: \.self, rowContent: { Text($0).font(.caption) })
                }
                if !showSys.isEmpty {
                    DisclosureGroup("提示词模板（首段预览；正文片段每段自动更换）") {
                        ScrollView {
                            Text(showSys + "\n\n────────\n\n" + showUser)
                                .font(.caption2).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 180)
                    }
                    .font(.caption)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("人物整理")
            .onAppear { refreshTemplate() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { task?.cancel(); dismiss() } } }
        }
    }

    private func refreshTemplate() {
        let source = AnalysisScope.text(for: project)
        let segments = PromptBuilder.segments(of: source, budget: SettingsStore.shared.segmentBudget)
        if let s0 = segments.first {
            let c0 = PromptBuilder.compileCharacterExtraction(project: project,
                                                              existingCards: project.characterCards,
                                                              segment: s0)
            showSys = c0.messages[0].content
            showUser = c0.messages[1].content
        }
    }

    private func run() {
        let source = AnalysisScope.text(for: project)
        let segments = PromptBuilder.segments(of: source, budget: SettingsStore.shared.segmentBudget)
        refreshTemplate()
        guard !segments.isEmpty else { log = ["锚前没有可分析的正文"]; return }
        guard SettingsStore.shared.activeCredential != nil else { log = ["尚未配置凭证"]; return }

        running = true
        processed = 0
        newCount = 0
        log = ["作用范围：\(AnalysisScope.label(for: project))，共 \(segments.count) 段"]

        task = Task {
            for (i, seg) in segments.enumerated() {
                if Task.isCancelled { break }
                progress = "第 \(i + 1)/\(segments.count) 段"

                let compiled = PromptBuilder.compileCharacterExtraction(project: project,
                                                                        existingCards: project.characterCards,
                                                                        segment: seg)
                let spec = AiTaskSpec(slot: .worker, temperature: 0.3, maxTokens: 6000,
                                      stage: "character", taskLabel: "整理")
                do {
                    let r = try await AiRunner.run(spec: spec, messages: compiled.messages,
                                                   context: context, projectID: project.id)
                    guard let chars = PromptBuilder.extractCharacters(from: r.text) else {
                        let preview = String(r.text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                        log.append("第 \(i + 1) 段无有效 JSON（\(r.finish.label)）：\(preview)")
                        continue
                    }
                    let added = apply(chars)
                    processed += 1
                    newCount += added
                    log.append("第 \(i + 1) 段：新建 \(added) 张，解析 \(chars.count) 个角色")
                } catch {
                    log.append("第 \(i + 1) 段失败：\(error.localizedDescription)")
                }
            }
            running = false
            progress = ""
            try? context.save()
        }
    }

    /// 写入卡片：同名或别称命中就补字段（只增不减），否则新建
    @discardableResult
    private func apply(_ chars: [[String: Any]]) -> Int {
        var added = 0
        for c in chars {
            let nm = str(c["name"])
            guard !nm.isEmpty else { continue }
            if let exist = project.characterCards.first(where: {
                $0.name == nm || $0.aliases.contains(nm)
            }) {
                merge(exist, c)
            } else {
                let card = CharacterCard(project: project, name: nm)
                card.aliases = str(c["aliases"])
                card.identity = str(c["identity"])
                card.goals = str(c["goals"])
                card.personality = str(c["personality"])
                card.speech = str(c["speech"])
                card.memories = str(c["memories"])
                card.attitudes = str(c["attitudes"])
                card.boundaries = str(c["boundaries"])
                context.insert(card)
                added += 1
            }
        }
        return added
    }

    private func merge(_ card: CharacterCard, _ c: [String: Any]) {
        card.aliases = mergeList(card.aliases, str(c["aliases"]))
        if card.identity.isEmpty { card.identity = str(c["identity"]) }
        if card.goals.isEmpty { card.goals = str(c["goals"]) }
        if card.personality.isEmpty { card.personality = str(c["personality"]) }
        if card.speech.isEmpty { card.speech = str(c["speech"]) }
        card.memories = appendLine(card.memories, str(c["memories"]))
        card.attitudes = appendLine(card.attitudes, str(c["attitudes"]))
        card.boundaries = appendLine(card.boundaries, str(c["boundaries"]))
        card.updatedAt = .now
    }

    private func str(_ v: Any?) -> String {
        ((v as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeList(_ a: String, _ b: String) -> String {
        guard !b.isEmpty else { return a }
        var seen = Set<String>()
        var out: [String] = []
        for part in (a + "、" + b).components(separatedBy: CharacterSet(charactersIn: "、,，;；/ ")) {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || seen.contains(t) { continue }
            seen.insert(t)
            out.append(t)
        }
        return out.joined(separator: "、")
    }

    private func appendLine(_ a: String, _ b: String) -> String {
        guard !b.isEmpty else { return a }
        if a.contains(b) { return a }
        return a.isEmpty ? b : a + "\n" + b
    }
}
