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
                Button("归纳") { showInduct = true }.disabled(project.body.isEmpty)
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
    @State private var added = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if running {
                    ProgressView(); Text("正在归纳…")
                    Button("停止归纳", role: .destructive) { task?.cancel() }
                } else {
                    Text(added == 0 ? "从正文归纳可迁移的写作规则（只增不减）" : "已归纳 \(added) 条规则")
                    Button("开始归纳") { run() }.buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("规则归纳")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { task?.cancel(); dismiss() } } }
        }
    }

    private func run() {
        running = true
        guard let cred0 = SettingsStore.shared.activeCredential else { running = false; return }
        var cred = cred0
        let m = SettingsStore.shared.model(for: "extract")
        if !m.isEmpty { cred.model = m }
        let existing = ((try? context.fetch(FetchDescriptor<WritingRule>())) ?? [])
            .filter { $0.project == project && $0.kind == "style" }.map(\.line)
        let seg = String(project.body.suffix(SettingsStore.shared.segmentBudget * 2))
        let compiled = PromptBuilder.compileRuleInduction(existingRules: existing, segment: seg)
        var acc = ""
        task = LlmClient.shared.stream(credential: cred, messages: compiled.messages, temperature: 0.4) { ev in
            if !ev.contentDelta.isEmpty { acc += ev.contentDelta }
            if let f = ev.finished {
                if !f.hasPrefix("error:") {
                DispatchQueue.main.async {
                    for line in acc.split(separator: "\n") {
                        let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "- •*")).trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || t.contains("NO_ADDITIONS") { continue }
                        context.insert(WritingRule(project: project, kind: "style", line: t))
                        added += 1
                    }
                    try? context.save()
                    running = false
                }
                } else {
                    DispatchQueue.main.async { running = false }
                }
            }
        }
    }
}
