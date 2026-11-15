import SwiftUI
import SwiftData

/// 基座自检（P0 验收入口）：凭证/槽位解析、单价、用量聚合、以及一次真实的 AiRunner 往返。
/// 验收基线：① 能进能出；② 预设/词表只读预览（在 StudioView 各段）；③ 走 AiRunner 记一条 usage。
struct StudioBaseCheckSheet: View {
    @Bindable var project: BookProject

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \UsageRecord.createdAt, order: .reverse) private var usage: [UsageRecord]

    @State private var running = false
    @State private var output = ""
    @State private var diag = ""
    @State private var errorText: String?

    private var settings: SettingsStore { SettingsStore.shared }

    private var projectSummary: UsageService.Summary {
        UsageService.summarizeProject(usage, projectID: project.id)
    }

    private var allSummary: UsageService.Summary {
        UsageService.summarize(usage)
    }

    private struct StageRow: Identifiable {
        var id: String
        var stat: UsageService.StageStat
    }

    private var stageRows: [StageRow] {
        projectSummary.byStage
            .sorted { $0.value.costCNY > $1.value.costCNY }
            .map { StageRow(id: $0.key, stat: $0.value) }
    }

    var body: some View {
        NavigationStack {
            Form {
                slotSection
                pricingSection
                usageSection
                selfCheckSection
                finishSection
            }
            .navigationTitle("基座自检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: 槽位

    private var slotSection: some View {
        Section("槽位解析") {
            if let cred = settings.activeCredential {
                LabeledContent("凭证", value: cred.name)
                LabeledContent("服务地址", value: cred.baseURL)
                let writer = AiRunner.resolve(slot: .writer)
                let worker = AiRunner.resolve(slot: .worker)
                LabeledContent("写作槽模型", value: writer?.model ?? "未解析")
                LabeledContent("杂务槽模型", value: worker?.model ?? "未解析")
                if settings.workerModel.isEmpty {
                    Text("杂务模型未单独配置：正回落到整理模型 → 凭证模型。审校/状态档这类短 JSON 任务配便宜模型更省。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("还没有凭证：设置 → 凭证管理").foregroundStyle(.orange).font(.caption)
            }
        }
    }

    // MARK: 单价

    private var pricingSection: some View {
        Section("单价（USD / 1M tokens）") {
            let pricing = UsagePricing.shared
            ForEach(pricing.models.keys.sorted(), id: \.self) { name in
                if let p = pricing.models[name] {
                    LabeledContent(name, value: String(format: "in %.2f · out %.2f · cache %.2f", p.input, p.output, p.cache))
                        .font(.caption)
                }
            }
            LabeledContent("汇率", value: String(format: "1 USD = ¥%.2f", pricing.cnyPerUSD))
            Text("未知模型名按「flash/mini/small/haiku → 便宜价，其余 → 高档价」回落。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: 用量

    private var usageSection: some View {
        Section("用量") {
            LabeledContent("本书调用", value: "\(projectSummary.calls) 次")
            LabeledContent("本书 tokens", value: projectSummary.tokens.formatted())
            LabeledContent("本书花费", value: String(format: "¥%.3f", projectSummary.costCNY))
            LabeledContent("全部花费", value: String(format: "¥%.3f", allSummary.costCNY))
            if stageRows.isEmpty {
                Text("本书还没有记录。跑一次下面的自检就会写一条。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(stageRows) { row in
                    LabeledContent(row.id, value: String(format: "%d 次 · ¥%.3f", row.stat.calls, row.stat.costCNY))
                        .font(.caption)
                }
            }
        }
    }

    // MARK: 自检

    private var selfCheckSection: some View {
        Section("AiRunner 往返") {
            Button {
                runSelfCheck()
            } label: {
                if running {
                    HStack { ProgressView(); Text("请求中…").padding(.leading, 6) }
                } else {
                    Label("跑一次（杂务槽 · 只回 ok）", systemImage: "bolt")
                }
            }
            .disabled(running || settings.activeCredential == nil)

            if !output.isEmpty {
                Text("回复：\(output)").font(.caption).textSelection(.enabled)
            }
            if !diag.isEmpty {
                Text(diag).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            Text("这条请求会记一条 UsageRecord（stage=selfcheck），并把 finish_reason 原样显示出来——包括 content_filter。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: 结束原因说明

    private var finishSection: some View {
        Section("结束原因怎么读") {
            VStack(alignment: .leading, spacing: 6) {
                Text("stop").font(.caption).bold() + Text(" 正常写完").font(.caption2)
                Text("length").font(.caption).bold() + Text(" 输出撞到 max_tokens 上限，正文可能是半截 —— 换更大预算重写").font(.caption2)
                Text("content_filter").font(.caption).bold() + Text(" 服务端按内容策略截断：同一提示词重试只会再被掐，要做的是换措辞/换模型/分段写").font(.caption2)
                Text("stopped").font(.caption).bold() + Text(" 人工或任务取消，已收到的半截保留").font(.caption2)
                Text("error:…").font(.caption).bold() + Text(" 中途错误帧或网络错误，原始片段保留").font(.caption2)
            }
        }
    }

    // MARK: 动作

    private func runSelfCheck() {
        guard !running else { return }
        running = true
        output = ""
        diag = ""
        errorText = nil

        let spec = AiTaskSpec(slot: .worker,
                              temperature: 0.2,
                              maxTokens: 32,
                              stage: "selfcheck",
                              taskLabel: "自检")
        let messages = [LlmMessage(role: "user", content: "只回复 ok")]

        Task {
            do {
                let r = try await AiRunner.run(spec: spec,
                                               messages: messages,
                                               context: context,
                                               projectID: project.id)
                await MainActor.run {
                    running = false
                    output = r.text.isEmpty ? "（空回复）" : r.text
                    diag = "结束原因：\(r.rawFinishReason.isEmpty ? "无" : r.rawFinishReason) · \(r.diagnosis)"
                }
            } catch {
                await MainActor.run {
                    running = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
