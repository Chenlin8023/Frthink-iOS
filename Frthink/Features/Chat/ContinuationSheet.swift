import SwiftUI
import SwiftData

/// 正式续写面板（唯一续写入口，书稿页与对话页共用）。
///
/// P1.1 修复：
/// - 呈现改 fullScreenCover（原来 .sheet 是居中卡片，横屏左右不到边）；
/// - 生成结果、思考、错误、用户改过的提示词全部存 `ContinuationStore`，面板重建/关闭重开都不丢；
/// - 采纳前自动写正文快照（原来漏了）。
struct ContinuationSheet: View {
    let project: BookProject
    var instruction: String = ""
    var onClose: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var store = ContinuationStore.shared

    // 预览态（可重建）
    @State private var preview: PromptBuilder.Compiled?
    @State private var useCards = true
    @State private var useWorld = true
    @State private var useCorpus = true
    @State private var useRules = true
    @State private var showAdvanced = false
    @State private var applyMode: ApplyMode = .append
    @State private var roundInstruction = ""
    @State private var task: Task<Void, Never>?

    enum ApplyMode: String, CaseIterable {
        case append = "追加到正文"
        case replaceTail = "从锚点替换"
        case chatOnly = "仅保存在气泡"
    }

    private var draft: ContinuationStore.Draft { store.draft(for: project.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                injectionCard
                instructionCard
                promptCard
                if !draft.thinking.isEmpty { thinkingCard }
                resultCard
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle("续写")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prepare)
    }

    // MARK: 注入清单

    private var injectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("注入内容").font(.subheadline).bold()
                Spacer()
                Button(showAdvanced ? "收起" : "高级") { showAdvanced.toggle() }
                    .font(.caption)
            }
            if let p = preview {
                Text("人物卡 \(p.injectedCards.count) 张 · 世界书命中 \(p.injectedWorld.count) 条 · 锚前尾部 \(p.tailLength) 字")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("锚：\(anchorLabel) · 作用范围：\(AnalysisScope.label(for: project))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("没有可注入的内容（正文为空？）").font(.caption2).foregroundStyle(.secondary)
            }
            if showAdvanced {
                HStack(spacing: 12) {
                    Toggle("人物卡", isOn: $useCards).font(.caption)
                    Toggle("世界书", isOn: $useWorld).font(.caption)
                }
                HStack(spacing: 12) {
                    Toggle("语料", isOn: $useCorpus).font(.caption)
                    Toggle("规则", isOn: $useRules).font(.caption)
                }
                .toggleStyle(.button)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .onChange(of: useCards) { _, _ in resetPrompts() }
        .onChange(of: useWorld) { _, _ in resetPrompts() }
        .onChange(of: useCorpus) { _, _ in resetPrompts() }
        .onChange(of: useRules) { _, _ in resetPrompts() }
    }

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本轮指令（情节要求，可空）").font(.caption).bold()
            HStack(spacing: 8) {
                TextField("这一轮要发生什么：如「他终于问出口」「打斗后两人独处」", text: $roundInstruction, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button("应用") { rebuildUser() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(roundInstruction.isEmpty)
            }
            Text("写进提示词的【本轮指令】段；留空 = 按前情自然往下写。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var anchorLabel: String {
        AnalysisScope.anchorIsExplicit(project) ? "第 \(AnalysisScope.anchor(of: project)) 字" : "未设（正文末尾）"
    }

    // MARK: 提示词（可编辑）

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("提示词（可改，改完直接生成）").font(.subheadline).bold()
            PromptEditorSection(
                systemText: Binding(
                    get: { draft.sysText },
                    set: { store.setPrompts(project.id, sys: $0, user: draft.userText) }
                ),
                userText: Binding(
                    get: { draft.userText },
                    set: { store.setPrompts(project.id, sys: draft.sysText, user: $0) }
                )
            )
            Button("恢复默认（按当前注入开关重编）") { resetPrompts() }
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: 思考

    private var thinkingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("思考块").font(.caption).bold()
            Text(draft.thinking.suffix(1200))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: 结果

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.running {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在生成… \(draft.text.count) 字")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let err = draft.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
            }
            if draft.hasResult {
                Text(draft.text)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                Text("\(draft.text.count) 字 · \(draft.finishReason.isEmpty ? "生成中" : draft.finishReason)")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !draft.running && draft.error == nil {
                Text("还没有结果。点下面「开始生成」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 底部操作

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if draft.hasResult && !draft.running {
                Picker("应用方式", selection: $applyMode) {
                    ForEach(ApplyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Button {
                        store.discard(project.id)
                    } label: {
                        Label("放弃", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        applyResult()
                    } label: {
                        Label("采纳", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        run()
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            } else if draft.running {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text("生成中…").font(.caption)
                    Spacer()
                    Button("停止", role: .destructive) {
                        task?.cancel()
                    }
                }
            } else {
                Button {
                    run()
                } label: {
                    Label(draft.hasResult ? "继续生成（会覆盖当前结果）" : "开始生成", systemImage: "text.append")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(SettingsStore.shared.activeCredential == nil || project.body.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: 预览与生成

    private func prepare() {
        if roundInstruction.isEmpty { roundInstruction = instruction }
        // 已有用户编辑过的提示词就不覆盖，只刷新注入统计
        if draft.sysText.isEmpty || draft.userText.isEmpty {
            buildPreview()
        } else {
            buildPreview(keepPrompts: true)
        }
    }

    private func buildPreview(keepPrompts: Bool = false) {
        let settings = SettingsStore.shared
        let bookRules = useRules
            ? ((try? context.fetch(FetchDescriptor<WritingRule>()))?.filter { $0.project == project } ?? [])
            : []
        let round = roundInstruction.isEmpty ? instruction : roundInstruction
        let compiled: PromptBuilder.Compiled
        if PromptBlockStore.hasCustom(project.id, .continuation) {
            // 用户改过提示词块：按块渲染（编排页与这里共用同一份配置）
            let blocks = PromptBlockStore.load(project.id, .continuation)
            let vars = PromptAssembler.vars(project: project,
                                            context: context,
                                            instruction: round,
                                            useCards: useCards,
                                            useWorld: useWorld,
                                            useCorpus: useCorpus)
            compiled = PromptAssembler.compose(project: project,
                                               context: context,
                                               instruction: round,
                                               blocks: blocks,
                                               vars: vars)
        } else {
            compiled = PromptBuilder.compileContinuation(
                project: project,
                instruction: round,
                globalRules: useRules ? ProjectData.globalRules(context: context) : [],
                bookRules: bookRules,
                worldEntries: useWorld ? ProjectData.worldEntries(project, context: context) : [],
                corpusEntries: useCorpus ? ProjectData.corpusEntries(project, context: context) : [],
                cards: useCards ? project.characterCards : [],
                contextBudget: settings.contextBudget)
        }
        preview = compiled
        if !keepPrompts {
            store.setPrompts(project.id,
                             sys: compiled.messages[0].content,
                             user: compiled.messages[1].content)
        }
    }

    /// 只按新的本轮指令重编 user 段，保留用户改过的 system
    private func rebuildUser() {
        let settings = SettingsStore.shared
        let bookRules = useRules
            ? ((try? context.fetch(FetchDescriptor<WritingRule>()))?.filter { $0.project == project } ?? [])
            : []
        let compiled = PromptBuilder.compileContinuation(
            project: project,
            instruction: roundInstruction,
            globalRules: useRules ? ProjectData.globalRules(context: context) : [],
            bookRules: bookRules,
            worldEntries: useWorld ? ProjectData.worldEntries(project, context: context) : [],
            corpusEntries: useCorpus ? ProjectData.corpusEntries(project, context: context) : [],
            cards: useCards ? project.characterCards : [],
            contextBudget: settings.contextBudget)
        preview = compiled
        store.setPrompts(project.id, sys: draft.sysText, user: compiled.messages[1].content)
    }

    private func resetPrompts() {
        store.resetPrompts(project.id)
        buildPreview()
    }

    private func run() {
        guard !draft.running else { return }
        guard let cred = SettingsStore.shared.activeCredential else {
            store.setError(project.id, "尚未配置凭证：设置 → 凭证管理")
            return
        }
        if draft.sysText.isEmpty || draft.userText.isEmpty { buildPreview() }

        store.begin(project.id, instruction: instruction)

        var cred2 = cred
        if !SettingsStore.shared.writingModel.isEmpty { cred2.model = SettingsStore.shared.writingModel }

        let messages = [LlmMessage(role: "system", content: draft.sysText),
                        LlmMessage(role: "user", content: draft.userText)]

        task = LlmClient.shared.stream(credential: cred2,
                                       messages: messages,
                                       temperature: SettingsStore.shared.temperature,
                                       maxTokens: SettingsStore.shared.maxOutputTokens) { ev in
            DispatchQueue.main.async {
                if !ev.contentDelta.isEmpty { store.appendContent(project.id, ev.contentDelta) }
                if !ev.thinkingDelta.isEmpty { store.appendThinking(project.id, ev.thinkingDelta) }
                if let usage = ev.usage {
                    UsageService.record(context: context,
                                        credentialName: cred.name,
                                        model: cred2.model,
                                        task: "写作",
                                        stage: "continuation",
                                        chapterIndex: nil,
                                        projectID: project.id,
                                        usage: TokenUsage(input: usage.input,
                                                          output: usage.output,
                                                          cached: usage.cached))
                }
                if let fin = ev.finished { store.finish(project.id, reason: fin) }
            }
        }
    }

    // MARK: 采纳

    private func applyResult() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 硬规则：正文变更前先快照
        context.insert(BodySnapshot(project: project, label: "续写采纳前", body: project.body))

        switch applyMode {
        case .append:
            project.body += (project.body.hasSuffix("\n") || project.body.isEmpty ? "" : "\n\n") + text
        case .replaceTail:
            let anchor = AnalysisScope.anchor(of: project)
            let head = TextSurgery.slice(project.body, start: 0, end: anchor)
            project.body = head + (head.hasSuffix("\n") ? "\n" : "\n\n") + text
        case .chatOnly:
            break
        }

        let bubble = ChatMessage(project: project, role: "assistant", content: text)
        bubble.thinking = String(draft.thinking.suffix(4000))
        bubble.finishReason = draft.finishReason
        context.insert(bubble)

        project.updatedAt = .now
        try? context.save()
        SettingsStore.shared.haptic()

        store.discard(project.id)
        dismiss()
        onClose?()
    }
}
