import SwiftUI
import SwiftData

/// 长期规则 / 味审查规则（对应 Android: 规则系统 + 增量归纳）
struct RulesView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @State private var newLine = ""
    @State private var showInduct = false

    private var bookStyle: [WritingRule] {
        ((try? context.fetch(FetchDescriptor<WritingRule>())) ?? [])
            .filter { $0.project == project && $0.kind == "style" }
            .sorted { $0.createdAt < $1.createdAt }
    }
    private var global: [WritingRule] {
        ProjectData.globalRules(context: context)
    }
    private var review: [WritingRule] {
        ((try? context.fetch(FetchDescriptor<WritingRule>())) ?? [])
            .filter { $0.project == project && $0.kind == "review" }
    }

    var body: some View {
        List {
            Section("全局规则（对所有书生效）") {
                if global.isEmpty { Text("暂无全局规则").foregroundStyle(.secondary).font(.caption) }
                ForEach(global) { r in
                    ruleRow(r)
                }
            }
            Section("本书长期规则") {
                if bookStyle.isEmpty { Text("暂无本书规则").foregroundStyle(.secondary).font(.caption) }
                ForEach(bookStyle) { r in ruleRow(r) }
                HStack {
                    TextField("新增规则（每行一条）", text: $newLine)
                    Button("保存") {
                        guard !newLine.isEmpty else { return }
                        context.insert(WritingRule(project: project, kind: "style", line: newLine))
                        newLine = ""; try? context.save()
                    }
                }
            }
            Section("味审查规则（生成后检查）") {
                if review.isEmpty { Text("审查规则已清空").foregroundStyle(.secondary).font(.caption) }
                ForEach(review) { r in ruleRow(r) }
            }
        }
        .navigationTitle("规则")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("归纳") { showInduct = true }
            }
        }
        .sheet(isPresented: $showInduct) { RuleInductSheet(project: project) }
    }

    private func ruleRow(_ r: WritingRule) -> some View {
        HStack {
            Text(r.line).font(.caption)
            Spacer()
            Button(role: .destructive) {
                context.delete(r); try? context.save()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}

/// 规则增量归纳（对应 Android: 增量模式，只输出新增规则）
struct RuleInductSheet: View {
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
                        HStack { ProgressView(); Text("正在归纳…") }
                        Button("停止归纳", role: .destructive) { task?.cancel() }
                    } else {
                        Button("开始归纳（使用下方提示词）") { run() }
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
            .navigationTitle("规则归纳")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { task?.cancel(); dismiss() } } }
            .onAppear(compile)
        }
    }

    private func compile() {
        let existing = ((try? context.fetch(FetchDescriptor<WritingRule>())) ?? [])
            .filter { $0.project == project && $0.kind == "style" }.map(\.line)
        let seg = String(project.body.suffix(SettingsStore.shared.segmentBudget * 2))
        let compiled = PromptBuilder.compileRuleInduction(existingRules: existing, segment: seg)
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
            temperature: 0.4) { ev in
            if !ev.contentDelta.isEmpty { acc += ev.contentDelta }
            if let f = ev.finished {
                DispatchQueue.main.async {
                    running = false
                    if f.hasPrefix("error:") { errorText = f; return }
                    rawText = acc
                    let n = saveParsed()
                    notice = n > 0 ? "已自动解析并保存 \(n) 条规则"
                                   : "已收到回复但未能自动解析——可在上方修正文本后点「解析并保存」"
                }
            }
        }
    }

    /// 从（可被用户修正过的）原始回复按行解析规则并入库
    @discardableResult
    private func saveParsed() -> Int {
        var n = 0
        for line in rawText.split(separator: "\n") {
            let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "- •*")).trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.contains("NO_ADDITIONS") || t == "```" { continue }
            context.insert(WritingRule(project: project, kind: "style", line: t))
            n += 1
        }
        try? context.save()
        if n > 0 { notice = "已保存 \(n) 条规则" }
        return n
    }
}
