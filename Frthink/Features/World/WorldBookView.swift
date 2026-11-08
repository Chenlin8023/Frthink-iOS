import SwiftUI
import SwiftData

/// 世界书（对应 Android: 世界书/词条注入）+ 语料库
/// 注意：导航栏按钮（语料库 / ＋ 新增词条）由 ProjectWorkspaceView 统一声明
struct WorldBookView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Binding var corpusSheet: Bool
    @Binding var newEntryRequest: Bool
    @State private var showEditor = false
    @State private var editing: WorldEntry?

    private var entries: [WorldEntry] {
        ProjectData.worldEntries(project, context: context)
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView("暂无词条", systemImage: "globe",
                                       description: Text("世界设定词条：关键词命中正文后注入"))
            }
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(e.title).font(.headline)
                        if e.project == nil {
                            Text("全局").font(.caption2).padding(3).background(Color.blue.opacity(0.15)).cornerRadius(4)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { e.enabled }, set: { e.enabled = $0 }))
                            .labelsHidden()
                    }
                    if !e.keywords.isEmpty {
                        Text("关键词：\(e.keywords)").font(.caption).foregroundStyle(.orange)
                    }
                    Text(e.content).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = e; showEditor = true }
                .contextMenu {
                    Button("删除词条", role: .destructive) {
                        context.delete(e); try? context.save()
                    }
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            WorldEntryEditor(project: project, entry: editing)
        }
        .sheet(isPresented: $corpusSheet) { CorpusListView(project: project) }
        .sheet(isPresented: $newEntryRequest) {
            WorldEntryEditor(project: project, entry: nil)
        }
    }
}

struct WorldEntryEditor: View {
    let project: BookProject
    var entry: WorldEntry?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var keywords = ""
    @State private var content = ""
    @State private var enabled = true

    var body: some View {
        NavigationStack {
            Form {
                TextField("词条标题", text: $title)
                TextField("触发关键词（顿号分隔，空＝常驻）", text: $keywords)
                TextField("词条内容", text: $content, axis: .vertical).lineLimit(6...20)
                Toggle("启用", isOn: $enabled)
            }
            .navigationTitle(entry == nil ? "新增词条" : "编辑词条")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let e = entry {
                            e.title = title; e.keywords = keywords; e.content = content
                            e.enabled = enabled; e.updatedAt = .now
                        } else {
                            context.insert(WorldEntry(project: project, title: title,
                                                      keywords: keywords, content: content))
                        }
                        try? context.save(); dismiss()
                    }.disabled(title.isEmpty)
                }
            }
            .onAppear {
                if let e = entry { title = e.title; keywords = e.keywords; content = e.content; enabled = e.enabled }
            }
        }
    }
}

/// 语料库（对应 Android: CorpusLibrary / 语料收集）
struct CorpusListView: View {
    let project: BookProject
    @Environment(\.modelContext) private var context
    @State private var newText = ""
    @State private var showCollect = false

    private var entries: [CorpusEntry] {
        ProjectData.corpusEntries(project, context: context).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("手动添加") {
                    TextField("新增语料（一条事实）", text: $newText, axis: .vertical)
                    Button("入库") {
                        guard !newText.isEmpty else { return }
                        context.insert(CorpusEntry(project: project, content: newText))
                        newText = ""
                        try? context.save()
                    }
                }
                Section("语料（\(entries.count) 条）") {
                    ForEach(entries) { e in
                        Text(e.content).font(.caption)
                            .contextMenu {
                                Button("删除语料", role: .destructive) {
                                    context.delete(e); try? context.save()
                                }
                            }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("语料收集") { showCollect = true }
                }
            }
            .navigationTitle("语料库")
            .sheet(isPresented: $showCollect) { CorpusCollectSheet(project: project) }
        }
    }
}

/// 语料收集（对应 Android: CorpusExtraction — 从正文提取设定事实）
struct CorpusCollectSheet: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var rawText = ""
    @State private var sysText = ""
    @State private var userText = ""
    @State private var errorText: String?
    @State private var notice = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if project.body.isEmpty { EmptyBodyHint() }
                    if running {
                        HStack { ProgressView(); Text("正在收集…") }
                        Button("停止收集", role: .destructive) { task?.cancel() }
                    } else {
                        Button("开始收集（使用下方提示词）") { run() }
                            .buttonStyle(.borderedProminent)
                            .disabled(project.body.isEmpty)
                    }
                    if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.green) }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    if !rawText.isEmpty {
                        Text("AI 原始回复（可修正后保存）").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $rawText).font(.caption).frame(minHeight: 140)
                            .border(Color.secondary.opacity(0.3))
                        Button("解析并保存") { saveParsed() }.buttonStyle(.bordered)
                    }
                    PromptEditorSection(systemText: $sysText, userText: $userText)
                }
                .padding()
            }
            .navigationTitle("语料收集")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { task?.cancel(); dismiss() } } }
            .onAppear(compile)
        }
    }

    private func compile() {
        let budget = SettingsStore.shared.segmentBudget
        let tail = String(project.body.suffix(budget * 3))
        let compiled = PromptBuilder.compileCorpusExtraction(segment: tail)
        sysText = compiled.messages[0].content
        userText = compiled.messages[1].content
    }

    private func run() {
        running = true
        errorText = nil
        notice = ""
        guard let cred0 = SettingsStore.shared.activeCredential else { running = false; errorText = "尚未配置凭证"; return }
        var cred = cred0
        let m = SettingsStore.shared.model(for: "extract")
        if !m.isEmpty { cred.model = m }
        var acc = ""
        task = LlmClient.shared.stream(
            credential: cred,
            messages: [LlmMessage(role: "system", content: sysText),
                       LlmMessage(role: "user", content: userText)],
            temperature: 0.3) { ev in
            if !ev.contentDelta.isEmpty { acc += ev.contentDelta }
            if let f = ev.finished {
                DispatchQueue.main.async {
                    running = false
                    if f.hasPrefix("error:") { errorText = f; return }
                    rawText = acc
                    let n = saveParsed()
                    notice = n > 0 ? "已自动解析并保存 \(n) 条语料"
                                   : "已收到回复但未能自动解析——可在上方修正文本后点「解析并保存」"
                }
            }
        }
    }

    /// 从（可被用户修正过的）原始回复按行解析语料并入库
    @discardableResult
    private func saveParsed() -> Int {
        var n = 0
        for line in rawText.split(separator: "\n") {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "- • ")).trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.contains("NO_ADDITIONS") || t == "```" { continue }
            context.insert(CorpusEntry(project: project, content: t, sourceRange: "正文尾部"))
            n += 1
        }
        try? context.save()
        if n > 0 { notice = "已保存 \(n) 条语料" }
        return n
    }
}

/// 事件卡（对应 Android: PlotEventCard）；「提取事件」按钮由 ProjectWorkspaceView 统一声明
struct EventsView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Binding var extractSheet: Bool
    @State private var showEditor = false
    @State private var editing: PlotEvent?

    var body: some View {
        List {
            if project.events.isEmpty {
                ContentUnavailableView("暂无事件", systemImage: "list.bullet.rectangle",
                                       description: Text("提取正文中的剧情事件（起因/发展/结果）"))
            }
            ForEach(project.events.sorted { $0.createdAt < $1.createdAt }) { ev in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ev.title).font(.headline)
                    if !ev.cause.isEmpty { Text("起因：\(ev.cause)").font(.caption) }
                    if !ev.development.isEmpty { Text("发展：\(ev.development)").font(.caption) }
                    if !ev.result.isEmpty { Text("结果：\(ev.result)").font(.caption) }
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = ev; showEditor = true }
                .contextMenu { Button("删除事件", role: .destructive) { context.delete(ev); try? context.save() } }
            }
        }
        .sheet(isPresented: $extractSheet) { EventExtractSheet(project: project) }
        .sheet(isPresented: $showEditor) { EventEditor(project: project, event: editing) }
    }
}

struct EventEditor: View {
    let project: BookProject
    var event: PlotEvent?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var cause = ""
    @State private var development = ""
    @State private var result = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("事件标题", text: $title)
                TextField("起因", text: $cause, axis: .vertical)
                TextField("发展", text: $development, axis: .vertical)
                TextField("结果", text: $result, axis: .vertical)
            }
            .navigationTitle(event == nil ? "新增事件" : "编辑事件")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let ev = event {
                            ev.title = title; ev.cause = cause; ev.development = development; ev.result = result
                        } else {
                            let ev = PlotEvent(project: project, title: title)
                            ev.cause = cause; ev.development = development; ev.result = result
                            context.insert(ev)
                        }
                        try? context.save(); dismiss()
                    }.disabled(title.isEmpty)
                }
            }
            .onAppear {
                if let ev = event { title = ev.title; cause = ev.cause; development = ev.development; result = ev.result }
            }
        }
    }
}

struct EventExtractSheet: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var rawText = ""
    @State private var sysText = ""
    @State private var userText = ""
    @State private var errorText: String?
    @State private var notice = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if project.body.isEmpty { EmptyBodyHint() }
                    if running {
                        HStack { ProgressView(); Text("正在提取…") }
                        Button("停止", role: .destructive) { task?.cancel() }
                    } else {
                        Button("开始提取（使用下方提示词）") { run() }
                            .buttonStyle(.borderedProminent)
                            .disabled(project.body.isEmpty)
                    }
                    if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.green) }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    if !rawText.isEmpty {
                        Text("AI 原始回复（可修正后保存）").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $rawText).font(.caption).frame(minHeight: 140)
                            .border(Color.secondary.opacity(0.3))
                        Button("解析并保存") { saveParsed() }.buttonStyle(.bordered)
                    }
                    PromptEditorSection(systemText: $sysText, userText: $userText)
                }
                .padding()
            }
            .navigationTitle("提取事件")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { task?.cancel(); dismiss() } } }
            .onAppear(compile)
        }
    }

    private func compile() {
        let existing = project.events.map(\.title)
        let seg = String(project.body.suffix(SettingsStore.shared.segmentBudget * 2))
        let compiled = PromptBuilder.compileEventExtraction(existingTitles: existing, segment: seg)
        sysText = compiled.messages[0].content
        userText = compiled.messages[1].content
    }

    private func run() {
        running = true
        errorText = nil
        notice = ""
        guard let cred0 = SettingsStore.shared.activeCredential else { running = false; errorText = "尚未配置凭证"; return }
        var cred = cred0
        let m = SettingsStore.shared.model(for: "extract")
        if !m.isEmpty { cred.model = m }
        var acc = ""
        task = LlmClient.shared.stream(
            credential: cred,
            messages: [LlmMessage(role: "system", content: sysText),
                       LlmMessage(role: "user", content: userText)],
            temperature: 0.3) { ev in
            if !ev.contentDelta.isEmpty { acc += ev.contentDelta }
            if let f = ev.finished {
                DispatchQueue.main.async {
                    running = false
                    if f.hasPrefix("error:") { errorText = f; return }
                    rawText = acc
                    let n = saveParsed()
                    notice = n > 0 ? "已自动解析并保存 \(n) 个事件"
                                   : "已收到回复但未能自动解析——可在上方修正文本后点「解析并保存」"
                }
            }
        }
    }

    /// 从（可被用户修正过的）原始回复解析 events JSON 并入库
    @discardableResult
    private func saveParsed() -> Int {
        guard let data = PromptBuilder.extractJSONObject(from: rawText),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else {
            errorText = "解析失败：回复中没有找到 {\"events\": [...]} 结构"
            return 0
        }
        var n = 0
        for e in events {
            guard let t = e["title"] as? String, !t.isEmpty else { continue }
            if project.events.contains(where: { $0.title == t }) { continue }
            let ev = PlotEvent(project: project, title: t)
            ev.cause = (e["cause"] as? String) ?? ""
            ev.development = (e["development"] as? String) ?? ""
            ev.result = (e["result"] as? String) ?? ""
            context.insert(ev)
            n += 1
        }
        try? context.save()
        if n > 0 { notice = "已保存 \(n) 个事件" }
        return n
    }
}
