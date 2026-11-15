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
    @State private var editingMessage: ChatMessage?
    @State private var showPromptStudio = false
    @State private var showAnchorSheet = false

    private var messages: [ChatMessage] {
        project.messages.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            rpHeader
            injectionBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { pair in
                            BubbleView(message: pair.element, project: project, floor: pair.offset + 1,
                                       onContinue: { send(override: "继续往下写，接上文。") },
                                       onRewrite: { rewrite(pair.element) },
                                       onEdit: { editingMessage = pair.element })
                                .id(pair.element.id)
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
            quickActions
                    pendingInstruction = "从续写锚之后继续写下去。"
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
                .fullScreenCover(isPresented: $showPromptStudio) { ModalPage { PromptStudioView(project: project) } }
        .fullScreenCover(isPresented: $showAnchorSheet) { ModalPage { AnchorSheet(project: project) } }
        .sheet(item: $editingMessage) { msg in
            BubbleEditSheet(message: msg)
        }
        .fullScreenCover(isPresented: $showPromptPreview) {
            ModalPage {
                ContinuationSheet(project: project,
                                  instruction: pendingInstruction.isEmpty ? input : pendingInstruction) {
                    pendingInstruction = ""
                }
            }
        }
    }
    // MARK: RP 头部（酒馆式：目录/资料/预设 三入口常驻在顶栏）

    private var rpHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.title).font(.subheadline).bold().lineLimit(1)
                Text(anchorLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            headerButton("text.badge.checkmark", "预设") { showPromptStudio = true }
            headerButton("anchor", "锚") { showAnchorSheet = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var anchorLine: String {
        let a = AnalysisScope.anchor(of: project)
        if AnalysisScope.anchorIsExplicit(project) {
            return "锚 第 \(a) 字 · 锚前 \(AnalysisScope.chapterCount(beforeAnchorOf: project)) 章"
        }
        return "锚 = 正文末尾 · \(project.body.count) 字"
    }

    private func headerButton(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.system(size: 9))
            }
            .frame(width: 42)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: 注入条（一眼看到本轮会注入多少）

    private var injectionBar: some View {
        let cards = project.characterCards.filter(\.enabled).count
        let corpus = ProjectData.corpusEntries(project, context: context).count
        return HStack(spacing: 12) {
            Label("\(cards) 人物", systemImage: "person.2")
            Label("\(corpus) 设定", systemImage: "books.vertical")
            Label("尾部 \(SettingsStore.shared.contextBudget)", systemImage: "text.alignleft")
            Spacer()
            Button("看提示词") { showPromptPreview = true }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground))
    }

    // MARK: 快捷操作

    private var quickActions: some View {
        HStack(spacing: 16) {
            Button { send(override: "继续往下写，接上文。") } label: {
                Label("继续", systemImage: "arrow.forward.to.line")
            }
            Button {
                if let last = messages.last(where: { $0.role == "assistant" }) { rewrite(last) }
            } label: {
                Label("重写上一条", systemImage: "arrow.clockwise")
            }
            if streaming {
                Button { streamTask?.cancel() } label: {
                    Label("停止", systemImage: "stop.circle")
                }
            }
            Spacer()
            Button { showPromptPreview = true } label: {
                Label("高级", systemImage: "slider.horizontal.3")
            }
        }
        .font(.caption2)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }


    /// RP 式重写：删掉这条回复，按它前面的用户指令重新生成
    private func rewrite(_ msg: ChatMessage) {
        let prevUser = messages.last { $0.role == "user" && $0.createdAt < msg.createdAt }?.content ?? ""
        context.delete(msg)
        try? context.save()
        send(override: prevUser.isEmpty ? "重写这一段。" : prevUser)
    }

    private func send(override: String? = nil) {
        let instruction = override ?? input
        if override == nil { input = "" }
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

// MARK: - 气泡（RP 式：可继续 / 重写 / 编辑 / 版本切换 / 追加到正文）
//
// 布局要点：assistant 气泡铺满可用宽度（旧版右侧留了 Spacer(minLength: 48) + 列表 16pt 内边距，
// 正文右侧固定空出 64pt，长文阅读很浪费）；user 气泡右侧对齐、左侧让出 56pt。

struct BubbleView: View {
    @Bindable var message: ChatMessage
    let project: BookProject
    var floor: Int? = nil
    var onContinue: (() -> Void)? = nil
    var onRewrite: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @State private var showThinking = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.thinking.isEmpty { thinkingBlock }
            bubble
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, isUser ? 56 : 0)
        .contextMenu { menu }
    }

    // MARK: 气泡本体

    private var bubble: some View {
        HStack(alignment: .top, spacing: 10) {
            if !isUser {
                Capsule()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(isUser ? "你" : "AI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionRow
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isUser ? 12 : 0)
        .background(isUser ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(12)
    }

    // MARK: 思考块

    private var thinkingBlock: some View {
        DisclosureGroup(isExpanded: $showThinking) {
            Text(message.thinking)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.12))
                .cornerRadius(8)
        } label: {
            Label("思考块", systemImage: "brain").font(.caption)
        }
    }

    // MARK: 元信息（对齐酒馆气泡：楼层 · 字数 · 估算 token · 时间）

    private var metaLine: some View {
        HStack(spacing: 8) {
            Text(isUser ? "你" : "AI").fontWeight(.semibold)
            if let floor {
                Text("#\(floor)").monospacedDigit()
            }
            Text("\(message.content.count) 字").monospacedDigit()
            Text("~\(estTokens) tok").monospacedDigit()
            Spacer()
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// 中文粗估：约 1.5 字 / token
    private var estTokens: Int {
        max(1, message.content.count * 2 / 3)
    }

    // MARK: 操作行

    private var actionRow: some View {
        HStack(spacing: 14) {
            if isUser {
                Button { onEdit?() } label: { Image(systemName: "pencil") }
                    .font(.caption)
            } else {
                Button { onContinue?() } label: {
                    Label("继续", systemImage: "arrow.forward.to.line")
                }
                .font(.caption)

                Button { onRewrite?() } label: {
                    Label("重写", systemImage: "arrow.clockwise")
                }
                .font(.caption)

                Button {
                    project.body += (project.body.hasSuffix("\n") || project.body.isEmpty ? "" : "\n\n") + message.content
                    project.updatedAt = .now
                    try? context.save()
                    SettingsStore.shared.haptic()
                } label: {
                    Label("追加到正文", systemImage: "plus.square.on.square")
                }
                .font(.caption)

                Button { onEdit?() } label: { Image(systemName: "pencil") }
                    .font(.caption)
            }

            versionSwitcher
            Spacer()
        }
    }

    @ViewBuilder
    private var versionSwitcher: some View {
        if !message.versions.isEmpty {
            HStack(spacing: 6) {
                Button {
                    if message.versionIndex > 0 {
                        message.versionIndex -= 1
                        message.content = message.versions[message.versionIndex]
                    }
                } label: { Image(systemName: "chevron.left") }

                Text("\(message.versionIndex + 1)/\(message.versions.count + 1)")
                    .font(.caption.monospacedDigit())

                Button {
                    if message.versionIndex < message.versions.count {
                        message.versionIndex += 1
                        message.content = message.versions[message.versionIndex]
                    }
                } label: { Image(systemName: "chevron.right") }
            }
            .font(.caption)
        }
    }

    // MARK: 长按菜单

    @ViewBuilder
    private var menu: some View {
        Button("复制消息") { UIPasteboard.general.string = message.content }
        if !isUser {
            Button("存为版本快照") { message.versions.append(message.content) }
            Button("继续写") { onContinue?() }
        }
        Button("删除气泡", role: .destructive) {
            context.delete(message)
            try? context.save()
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

/// 编辑单条气泡（RP 式：改完直接改库里的内容，旧内容进 versions）
struct BubbleEditSheet: View {
    @Bindable var message: ChatMessage
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(minHeight: 260)
                }
                Section {
                    Text("\(text.count) 字").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑气泡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        message.versions.append(message.content)
                        message.content = text
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onAppear { text = message.content }
        }
    }
}
