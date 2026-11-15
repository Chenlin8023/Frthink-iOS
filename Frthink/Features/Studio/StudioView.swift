import SwiftUI
import SwiftData

/// 制作台的五个工作段（reports/10 §7.2）。P0 只搭骨架 + 只读预览，功能随 P1–P5 逐段落进去。
enum StudioPane: String, CaseIterable, Identifiable {
    case structure, outline, state, pipeline, marks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structure: return "结构"
        case .outline: return "大纲"
        case .state: return "状态"
        case .pipeline: return "生成重制"
        case .marks: return "意见"
        }
    }

    var plannedIn: String {
        switch self {
        case .structure: return "P1：ChapterUnit 章/剧情点/段 卡片、命名锚点、范围预览"
        case .outline: return "P2：OutlineItem、提取/规划、自动打标、责编审、按意见改"
        case .state: return "P3：StoryState 回填、逐章快照、前情卡"
        case .pipeline: return "P4/P5：逐章重制与生成、采纳手术、批量四件套"
        case .marks: return "P3：ReaderMark 逐章意见，注入下一次生成"
        }
    }
}

/// 制作台（ModalPage 内）：五个工作段共用一个项目上下文。
struct StudioView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Query(sort: \UsageRecord.createdAt, order: .reverse) private var usage: [UsageRecord]

    @State private var pane: StudioPane = .structure
    @State private var showBaseCheck = false

    private var plan: ContentPlan { ContentPlan.load(from: project) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("工作段", selection: $pane) {
                ForEach(StudioPane.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    paneHeader
                    paneBody
                    baseCard
                }
                .padding(16)
            }
        }
        .navigationTitle("制作台")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBaseCheck) {
            StudioBaseCheckSheet(project: project)
        }
    }

    // MARK: 头部

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pane.title).font(.title3).bold()
            Text(pane.plannedIn).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 各段

    @ViewBuilder
    private var paneBody: some View {
        switch pane {
        case .structure: StructurePane(project: project)
        case .outline: OutlinePane(project: project, plan: plan)
        case .state: StatePane(plan: plan)
        case .pipeline: PipelinePane(project: project, plan: plan, usage: usage)
        case .marks: MarksPane(project: project)
        }
    }

    // MARK: 基座卡（P0 自检入口，长期保留：注入预览/用量/凭证诊断都从这里进）

    private var baseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("基座自检（P0）").font(.subheadline).bold()
            Text("当前档案：\(plan.summaryLine)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    showBaseCheck = true
                } label: {
                    Label("打开基座自检", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)

                Button {
                    showBaseCheck = true
                } label: {
                    Label("查看用量", systemImage: "chart.bar")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - 结构段（P0 只读预览：用现有正则数一遍章节，证明底座可用）

struct StructurePane: View {
    let project: BookProject

    private var chapters: [(title: String, offset: Int)] {
        PromptBuilder.chapterRanges(in: project.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("正文", value: "\(project.body.count) 字")
            LabeledContent("识别到的章节", value: "\(chapters.count) 章")
            if let a = project.anchorOffset {
                LabeledContent("当前续写锚", value: "第 \(a) 字")
            } else {
                LabeledContent("当前续写锚", value: "未设（续写从正文结尾）")
            }
            if chapters.isEmpty {
                Text("没有识别到章节标题。P1 会在这里显示空行段兜底卡片，并支持自定义章节正则。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(Array(chapters.prefix(8).enumerated()), id: \.offset) { pair in
                    HStack(spacing: 8) {
                        Text("\(pair.offset + 1)")
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        Text(pair.element.title)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        Text("第 \(pair.element.offset) 字")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if chapters.count > 8 {
                    Text("（只显示前 8 章）").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("P1 会把它们落成 ChapterUnit（可改名/合并/拆分、设分析范围、命名锚点）。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - 大纲段

struct OutlinePane: View {
    let project: BookProject
    let plan: ContentPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("尺度档", value: plan.levelExplicitlySet ? plan.level.title : "未选择（默认 \(plan.level.title)）")
            LabeledContent("节奏", value: "第 \(plan.cadenceStart) 章起每 \(plan.cadenceEvery) 章一场")
            LabeledContent("群体场面", value: plan.groupScenes > 0 ? "\(plan.groupScenes) 场" : "不要")
            LabeledContent("词表", value: "\(ContentKit.tagGroups.count) 组 · \(ContentKit.allTags.count) 词")
            LabeledContent("基调", value: plan.tone.isEmpty ? "未设" : "已设（\(plan.tone.count) 字）")

            Divider()
            Text("内置标签词表").font(.footnote).bold()
            ForEach(ContentKit.tagGroups) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.g).font(.caption2).foregroundStyle(.secondary)
                    Text(g.t.joined(separator: " · "))
                        .font(.caption2)
                }
                .padding(.vertical, 2)
            }
            Text("P2 会在这里生成大纲、逐章打标、责编审、按意见改；词表只作装配索引，正文不从这里取措辞。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - 状态段

struct StatePane: View {
    let plan: ContentPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关系维度（\(plan.dimSet.title)）").font(.footnote).bold()
            ForEach(plan.dims) { d in
                HStack(spacing: 8) {
                    Text(d.n).font(.caption).frame(width: 42, alignment: .leading)
                    ProgressView(value: Double(d.initial), total: 100)
                    Text("\(d.initial)")
                        .font(.caption2).monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
                Text(d.d).font(.caption2).foregroundStyle(.secondary)
            }
            Text("P3 会按章回填状态档（每章一条快照），并把这份维度表渲染成续写时的【前情】块。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - 生成重制段

struct PipelinePane: View {
    let project: BookProject
    let plan: ContentPlan
    let usage: [UsageRecord]

    private var summary: UsageService.Summary {
        UsageService.summarizeProject(usage, projectID: project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("单章目标", value: "\(plan.targetChapterChars) 字")
            LabeledContent("每章估价上限", value: String(format: "¥%.2f", SettingsStore.shared.perChapterBudget))
            LabeledContent("本书累计调用", value: "\(summary.calls) 次")
            LabeledContent("本书累计花费", value: String(format: "¥%.2f", summary.costCNY))
            if !plan.remakeInstruction.isEmpty {
                Divider()
                Text("全书指令").font(.footnote).bold()
                Text(plan.remakeInstruction).font(.caption)
            }
            Divider()
            Text("进度占位").font(.footnote).bold()
            Text("P4 落地：逐章重制（先草稿后采纳、采纳前自动快照）")
                .font(.caption2).foregroundStyle(.secondary)
            Text("P5 落地：无正文的规划章生成 / 缺章补写，与重制共用同一条流水")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - 意见段

struct MarksPane: View {
    let project: BookProject

    private var paragraphs: Int {
        project.body.components(separatedBy: "\n\n").count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("正文段落", value: "\(paragraphs) 段")
            Text("P3 落地：在章内某段长按即可加一条意见（想改 / 写得不对 / 节奏慢），重制或续写时按章注入，用过一次标记为已消费。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
