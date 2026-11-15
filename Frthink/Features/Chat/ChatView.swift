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

    private var messages: [ChatMessage] {
        project.messages.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { msg in
                            BubbleView(message: msg, project: project,
                                       onContinue: { send(override: "继续往下写，接上文。") },
                                       onRewrite: { rewrite(msg) },
                                       onEdit: { editingMessage = msg })
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
        VStack(alignment: .leading, spacing: 10) {
            Text(message.content)
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            actionRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
        .cornerRadius(14)
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
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
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
