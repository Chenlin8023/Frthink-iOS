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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if project.body.isEmpty {
                    EmptyBodyHint()
                }
                HStack {
                    if running {
                        ProgressView().padding(.trailing, 4)
                        Text(progress)
                    } else {
                        Text(processed == 0 ? "将把正文分段整理为人物卡（增量模式，只增不减）"
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
                Spacer()
            }
            .padding()
            .navigationTitle("人物整理")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { task?.cancel(); dismiss() } } }
        }
    }

    private func run() {
        let segments = PromptBuilder.segments(of: project.body, budget: SettingsStore.shared.segmentBudget)
        running = true
        processed = 0; newCount = 0; log = []
        guard let cred = SettingsStore.shared.activeCredential else {
            log.append("尚未配置凭证"); running = false; return
        }
        var cred2 = cred
        let m = SettingsStore.shared.model(for: "extract")
        if !m.isEmpty { cred2.model = m }

        task = Task {
            for (i, seg) in segments.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run { progress = "第 \(i+1)/\(segments.count) 段" }
                let existing = project.characterCards
                let compiled = PromptBuilder.compileCharacterExtraction(project: project,
                                                                        existingCards: existing, segment: seg)
                var got = ""
                let done = await withCheckedContinuation { cont in
                    _ = LlmClient.shared.stream(credential: cred2, messages: compiled.messages,
                                                temperature: 0.3, maxTokens: 2000) { ev in
                        if !ev.contentDelta.isEmpty { got += ev.contentDelta }
                        if let f = ev.finished {
                            if f != "error:任务已停止" { cont.resume(returning: true) }
                            else if f.hasPrefix("error:") { cont.resume(returning: false) }
                        }
                    }
                }
                guard done, let data = PromptBuilder.extractJSONObject(from: got),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let chars = obj["characters"] as? [[String: Any]] else {
                    await MainActor.run { log.append("第 \(i+1) 段没有返回有效 JSON，已跳过") }
                    continue
                }
                await MainActor.run {
                    var added = 0
                    for c in chars {
                        guard let nm = c["name"] as? String, !nm.isEmpty else { continue }
                        // 去重：同名或别称命中 → 合并新字段（只增不减）
                        if let exist = project.characterCards.first(where: {
                            $0.name == nm || $0.aliases.contains(nm)
                        }) {
                            if let v = c["aliases"] as? String, !v.isEmpty, !exist.aliases.contains(v) {
                                exist.aliases += (exist.aliases.isEmpty ? "" : "、") + v }
                            if let v = c["memories"] as? String, !v.isEmpty { exist.memories += "\n" + v }
                            if let v = c["attitudes"] as? String, !v.isEmpty { exist.attitudes += "\n" + v }
                            if (exist.personality.isEmpty), let v = c["personality"] as? String { exist.personality = v }
                        } else {
                            let card = CharacterCard(project: project, name: nm)
                            card.aliases = (c["aliases"] as? String) ?? ""
                            card.identity = (c["identity"] as? String) ?? ""
                            card.goals = (c["goals"] as? String) ?? ""
                            card.personality = (c["personality"] as? String) ?? ""
                            card.speech = (c["speech"] as? String) ?? ""
                            card.memories = (c["memories"] as? String) ?? ""
                            card.attitudes = (c["attitudes"] as? String) ?? ""
                            context.insert(card)
                            added += 1
                        }
                    }
                    newCount += added
                    processed += 1
                    log.append("第 \(i+1) 段完成：新建 \(added) 张卡")
                    try? context.save()
                }
            }
            await MainActor.run { running = false }
        }
    }
}
