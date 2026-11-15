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
        .fullScreenCover(isPresented: $showPromptPreview) {
            ModalPage {
                ContinuationSheet(project: project,
                                  instruction: pendingInstruction.isEmpty ? input : pendingInstruction) {
                    pendingInstruction = ""
                }
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
