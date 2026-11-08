import SwiftUI
import SwiftData

/// AI 对话（对应 Android: 续写气泡 / 版本 / 思考块 / 停止 / 提示词预览）
struct ChatView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @State private var input = ""
    @State private var streaming = false
    @State private var streamContent = ""
    @State private var streamThinking = ""
    @State private var statusText = ""
    @State private var errorText: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var showPromptPreview = false
    @State private var pendingInstruction = ""

    private var messages: [ChatMessage] {
        project.messages.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { msg in
                            BubbleView(message: msg, project: project)
                                .id(msg.id)
                        }
                        if streaming {
                            StreamingBubbleView(content: streamContent, thinking: streamThinking, status: statusText)
                                .id("streaming")
                        }
                    }
                    .padding()
                }
                .onChange(of: streamContent) { _, _ in
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    pendingInstruction = "从书稿结尾之后继续写下去。"
                    showPromptPreview = true
                } label: {
                    Image(systemName: "anchor")
                }
                .disabled(streaming || project.body.isEmpty)

                TextField("本轮指令（可空＝继续写）", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                if streaming {
                    Button(role: .destructive) {
                        streamTask?.cancel()
                        statusText = "可发送停止…"
                    } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .disabled(input.isEmpty && project.body.isEmpty)
                }
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showPromptPreview) {
            ContinuationSheet(project: project, instruction: pendingInstruction.isEmpty ? input : pendingInstruction) {
                pendingInstruction = ""
            }
        }
    }

    private func send() {
        let instruction = input
        input = ""
        streaming = true
        streamContent = ""
        streamThinking = ""
        errorText = nil
        statusText = "正在生成…可发送停止"

        if !instruction.isEmpty {
            context.insert(ChatMessage(project: project, role: "user", content: instruction))
            try? context.save()
        }

        let settings = SettingsStore.shared
        guard let cred = settings.activeCredential else {
            streaming = false
            statusText = ""
            let m = ChatMessage(project: project, role: "assistant",
                                content: "尚未配置模型凭证，请到「设置 → 凭证管理」配置。")
            context.insert(m); try? context.save()
            return
        }

        // 使用当前展示消息历史做上下文（对应 Android: 对话历史 + 摘要）
        var history: [LlmMessage] = []
        let prior = messages.filter { $0.role == "assistant" }.suffix(4)
        for m in prior where !m.content.isEmpty {
            history.append(LlmMessage(role: "assistant", content: String(m.content.suffix(1500))))
        }

        let compiled = PromptBuilder.compileContinuation(
            project: project,
            instruction: instruction,
            globalRules: ProjectData.globalRules(context: context),
            bookRules: (try? context.fetch(FetchDescriptor<WritingRule>()))?
                .filter { $0.project == project } ?? [],
            worldEntries: ProjectData.worldEntries(project, context: context),
            corpusEntries: ProjectData.corpusEntries(project, context: context),
            cards: project.characterCards,
            contextBudget: settings.contextBudget)

        let reqMessages = [compiled.messages[0]] + history + [compiled.messages[1]]

        var tempCred = cred
        if !settings.writingModel.isEmpty { tempCred.model = settings.writingModel }

        streamTask = LlmClient.shared.stream(credential: tempCred, messages: reqMessages,
                                             temperature: settings.temperature,
                                             maxTokens: settings.maxOutputTokens) { ev in
            DispatchQueue.main.async {
                if !ev.contentDelta.isEmpty { streamContent += ev.contentDelta }
                if !ev.thinkingDelta.isEmpty { streamThinking += ev.thinkingDelta }
                if let usage = ev.usage {
                    context.insert(UsageRecord(credentialName: cred.name, model: tempCred.model,
                                               task: "写作", inputTokens: usage.input,
                                               outputTokens: usage.output, cachedTokens: usage.cached))
                }
                if let fin = ev.finished {
                    if fin.hasPrefix("error:") { errorText = fin }
                    finishStreaming(finishReason: fin)
                }
            }
        }
    }

    private func finishStreaming(finishReason: String) {
        streaming = false
        statusText = ""
        if finishReason.hasPrefix("error:") {
            // 中断/报错：已收到的半截内容必须保留（对应"气泡消失"问题的修复）
            let m: ChatMessage
            if !streamContent.isEmpty {
                m = ChatMessage(project: project, role: "assistant",
                                content: streamContent + "\n\n（⚠️ 生成中断：\(finishReason)）")
                m.thinking = streamThinking
            } else {
                m = ChatMessage(project: project, role: "assistant",
                                content: "生成失败：\(finishReason)")
            }
            m.finishReason = finishReason
            context.insert(m); try? context.save()
            return
        }
        let truncNote: String
        switch finishReason {
        case "content_filter": truncNote = "\n\n（⚠️ 服务端内容过滤，回复被截断）"
        case "stopped": truncNote = "\n\n（⏹ 已手动停止）"
        default: truncNote = ""
        }
        // 只有思考块没有正文也保存（此前直接丢弃导致"气泡消失"）
        guard !streamContent.isEmpty || !streamThinking.isEmpty else { return }
        let m = ChatMessage(project: project, role: "assistant", content: streamContent + truncNote)
        m.thinking = streamThinking
        m.finishReason = finishReason
        context.insert(m)
        try? context.save()
        SettingsStore.shared.haptic()
    }
}

// MARK: - 气泡（含版本切换、追加到正文、思考块）

struct BubbleView: View {
    @Bindable var message: ChatMessage
    let project: BookProject
    @Environment(\.modelContext) private var context
    @State private var showThinking = false

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if !message.thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        Text(message.thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.yellow.opacity(0.12))
                            .cornerRadius(8)
                    } label: {
                        Label("思考块", systemImage: "brain")
                            .font(.caption)
                    }
                }
                Text(message.content)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    if message.role == "assistant" {
                        Button {
                            project.body += (project.body.hasSuffix("\n") || project.body.isEmpty ? "" : "\n\n") + message.content
                            project.updatedAt = .now
                            try? context.save()
                            SettingsStore.shared.haptic()
                        } label: {
                            Label("追加到正文", systemImage: "plus.square.on.square").font(.caption)
                        }
                    }
                    if !message.versions.isEmpty {
                        Button {
                            if message.versionIndex > 0 { message.versionIndex -= 1; message.content = message.versions[message.versionIndex] }
                        } label: { Image(systemName: "chevron.left") }.font(.caption)
                        Text("\(message.versionIndex + 1)/\(message.versions.count + 1)").font(.caption.monospacedDigit())
                        Button {
                            if message.versionIndex < message.versions.count {
                                message.versionIndex += 1
                                message.content = message.versions[message.versionIndex]
                            }
                        } label: { Image(systemName: "chevron.right") }.font(.caption)
                    }
                    Spacer()
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(message.role == "user" ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            .cornerRadius(14)
            if message.role != "user" { Spacer(minLength: 48) }
        }
        .contextMenu {
            Button("复制消息") { UIPasteboard.general.string = message.content }
            if message.role == "assistant" && message.content.count > 0 {
                Button("设为回复版本快照") {
                    message.versions.append(message.content)
                }
            }
            Button("删除气泡", role: .destructive) {
                context.delete(message)
                try? context.save()
            }
        }
    }
}

struct StreamingBubbleView: View {
    let content: String
    let thinking: String
    let status: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if !thinking.isEmpty {
                    Text(thinking.suffix(500))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(8)
                        .background(Color.yellow.opacity(0.12))
                        .cornerRadius(8)
                }
                Text(content.isEmpty ? status : content)
                    .textSelection(.enabled)
                HStack {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).opacity(0.6)
                    Text("正在工作").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
            Spacer(minLength: 48)
        }
    }
}

// MARK: - 续写预览/确认（对应 Android: 提示词预览 → 生成 → 确认追加）

struct ContinuationSheet: View {
    let project: BookProject
    var instruction: String = ""
    var onClose: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var preview: PromptBuilder.Compiled?
    @State private var result = ""
    @State private var thinking = ""
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var errorText: String?
    @State private var applyMode: ApplyMode = .append
    // 酒馆式注入开关（对应 Android: PromptBlockPreference）
    @State private var useCards = true
    @State private var useWorld = true
    @State private var useCorpus = true
    @State private var useRules = true
    // 可编辑提示词（反黑箱）
    @State private var editSys = ""
    @State private var editUser = ""

    enum ApplyMode: String, CaseIterable { case append = "追加到正文"; case replaceTail = "从锚点替换"; case chatOnly = "仅保存在气泡" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let preview, result.isEmpty && !running {
                        HStack(spacing: 12) {
                            Toggle("人物卡", isOn: $useCards).font(.caption)
                            Toggle("世界书", isOn: $useWorld).font(.caption)
                        }
                        HStack(spacing: 12) {
                            Toggle("语料", isOn: $useCorpus).font(.caption)
                            Toggle("规则", isOn: $useRules).font(.caption)
                        }
                        .toggleStyle(.button)
                        .onChange(of: useCards) { _, _ in buildPreview() }
                        .onChange(of: useWorld) { _, _ in buildPreview() }
                        .onChange(of: useCorpus) { _, _ in buildPreview() }
                        .onChange(of: useRules) { _, _ in buildPreview() }
                        promptPreview(preview)
                        PromptEditorSection(systemText: $editSys, userText: $editUser)
                    }
                    if running {
                        HStack { ProgressView(); Text("正在生成…") }
                    }
                    if !thinking.isEmpty {
                        Text(thinking.suffix(800))
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(8).background(Color.yellow.opacity(0.1)).cornerRadius(8)
                    }
                    if !result.isEmpty {
                        Text(result).textSelection(.enabled).padding(8)
                            .background(Color(.secondarySystemBackground)).cornerRadius(8)
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                            .padding(8).background(Color.red.opacity(0.08)).cornerRadius(8)
                    }
                }
                .padding()
            }
            .navigationTitle("续写")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { task?.cancel(); dismiss(); onClose?() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if running {
                        Button("停止", role: .destructive) { task?.cancel() }
                    } else if result.isEmpty {
                        Button("开始生成") { run() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !result.isEmpty {
                    VStack(spacing: 8) {
                        Picker("应用方式", selection: $applyMode) {
                            ForEach(ApplyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Button("确认应用") {
                            applyResult()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("放弃修改", role: .destructive) { dismiss() }
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .onAppear(perform: buildPreview)
        }
    }

    private func buildPreview() {
        let settings = SettingsStore.shared
        let bookRules = useRules
            ? ((try? context.fetch(FetchDescriptor<WritingRule>()))?
                .filter { $0.project == project } ?? []) : []
        preview = PromptBuilder.compileContinuation(
            project: project, instruction: instruction,
            globalRules: useRules ? ProjectData.globalRules(context: context) : [],
            bookRules: bookRules,
            worldEntries: useWorld ? ProjectData.worldEntries(project, context: context) : [],
            corpusEntries: useCorpus ? ProjectData.corpusEntries(project, context: context) : [],
            cards: useCards ? project.characterCards : [],
            contextBudget: settings.contextBudget)
        if let p = preview {
            editSys = p.messages[0].content
            editUser = p.messages[1].content
        }
    }

    private func promptPreview(_ p: PromptBuilder.Compiled) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("提示词预览（发送前可检查）").font(.headline)
            if !p.injectedWorld.isEmpty { Text("注入世界词条：\(p.injectedWorld.joined(separator: "、"))").font(.caption) }
            if !p.injectedCards.isEmpty { Text("注入人物卡：\(p.injectedCards.joined(separator: "、"))").font(.caption) }
            Text("注入正文尾部：\(p.tailLength) 字").font(.caption)
            Text(p.messages[0].content)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(6)
                .padding(8).background(Color(.tertiarySystemBackground)).cornerRadius(8)
        }
    }

    private func run() {
        guard let cred = SettingsStore.shared.activeCredential, !editSys.isEmpty || !editUser.isEmpty else { return }
        running = true
        result = ""
        errorText = nil
        var cred2 = cred
        if !SettingsStore.shared.writingModel.isEmpty { cred2.model = SettingsStore.shared.writingModel }
        task = LlmClient.shared.stream(credential: cred2,
                                       messages: [LlmMessage(role: "system", content: editSys),
                                                  LlmMessage(role: "user", content: editUser)],
                                       temperature: SettingsStore.shared.temperature,
                                       maxTokens: SettingsStore.shared.maxOutputTokens) { ev in
            DispatchQueue.main.async {
                if !ev.contentDelta.isEmpty { result += ev.contentDelta }
                if !ev.thinkingDelta.isEmpty { thinking += ev.thinkingDelta }
                if let fin = ev.finished {
                    if fin.hasPrefix("error:") { errorText = fin }
                    running = false
                }
            }
        }
    }

    private func applyResult() {
        switch applyMode {
        case .append:
            project.body += (project.body.hasSuffix("\n") || project.body.isEmpty ? "" : "\n\n") + result
            context.insert(ChatMessage(project: project, role: "user", content: instruction.isEmpty ? "（继续写）" : instruction))
        case .replaceTail:
            if let anchor = project.anchorOffset, project.body.count >= anchor {
                project.body = String(project.body.prefix(anchor)) + "\n\n" + result
            } else {
                project.body += result
            }
        case .chatOnly:
            break
        }
        let m = ChatMessage(project: project, role: "assistant", content: result)
        m.thinking = thinking
        context.insert(m)
        project.updatedAt = .now
        try? context.save()
        SettingsStore.shared.haptic()
    }
}
