import SwiftUI
import SwiftData

/// 基调与尺度（内容档案编辑器）。
/// 唯一写入路径：改本地 ContentPlan → `apply(to:)` → save。
/// `contentLevel` 的三态：nil = 还没选过（首次进来时高亮"选一个"），`off` = 明确不写。
struct ContentPlanEditor: View {
    @Bindable var project: BookProject

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var plan = ContentPlan()
    @State private var presetName = ""
    @State private var loaded = false
    @State private var showRulesEditor = false

    var body: some View {
        NavigationStack {
            Form {
                if !plan.levelExplicitlySet { firstRunSection }
                levelSection
                presetSection
                cadenceSection
                toneSection
                dimsSection
                rulesSection
                instructionSection
                footerSection
            }
            .navigationTitle("基调与尺度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear(perform: loadPlan)
        }
    }

    // MARK: 首次提示

    private var firstRunSection: some View {
        Section {
            Text("这本书还没选过尺度档。先选一档，后面所有大纲与正文任务都按它走；随时可以改。")
                .font(.caption)
        } header: {
            Text("首次设置")
        }
    }

    // MARK: 尺度

    private var levelSection: some View {
        Section {
            Picker("尺度档", selection: $plan.level) {
                ForEach(ContentPlan.Level.allCases) { lv in
                    Text(lv.title).tag(lv)
                }
            }
            .onChange(of: plan.level) { _, _ in
                plan.levelExplicitlySet = true
            }
            Text(plan.level.detail).font(.caption2).foregroundStyle(.secondary)
            Text("规则模板里的 18 条文风纪律始终生效；这一档只决定场面写到什么程度。")
                .font(.caption2).foregroundStyle(.secondary)
        } header: {
            Text("尺度")
        }
    }

    // MARK: 基调预设

    private var presetSection: some View {
        Section {
            Picker("套用预设", selection: $presetName) {
                Text("不套用").tag("")
                ForEach(ContentKit.tonePresets) { p in
                    Text(p.name).tag(p.name)
                }
            }
            .onChange(of: presetName) { _, newValue in
                guard let p = ContentKit.tonePresets.first(where: { $0.name == newValue }) else { return }
                plan.applyPreset(p)
            }
            if let p = ContentKit.tonePresets.first(where: { $0.name == presetName }) {
                Text("预设会写入基调、节奏（第 \(p.cadenceStart) 章起每 \(p.cadenceEvery) 章一场）与关系维度；默认标记：\(p.opts.isEmpty ? "无" : p.opts.joined(separator: "、"))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("基调预设")
        }
    }

    // MARK: 节奏

    private var cadenceSection: some View {
        Section {
            Stepper("第 \(plan.cadenceStart) 章起安排第一场", value: $plan.cadenceStart, in: 1...30)
            Stepper("之后每 \(plan.cadenceEvery) 章一场", value: $plan.cadenceEvery, in: 1...10)
            Stepper("群体场面 \(plan.groupScenes) 场", value: $plan.groupScenes, in: 0...8)
            Stepper("单章目标 \(plan.targetChapterChars) 字", value: $plan.targetChapterChars, in: 800...12000, step: 200)
        } header: {
            Text("节奏（大纲规划用）")
        }
    }

    // MARK: 基调

    private var toneSection: some View {
        Section {
            TextEditor(text: $plan.tone)
                .font(.caption)
                .frame(minHeight: 110)
            TextField("视角人物（写手规则第 1 条）", text: $plan.perspective)
                .autocorrectionDisabled()
        } header: {
            Text("整书基调（优先级高于通用规则）")
        }
    }

    // MARK: 维度

    private var dimsSection: some View {
        Section {
            Picker("维度集", selection: $plan.dimSet) {
                ForEach(ContentKit.DimSet.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .onChange(of: plan.dimSet) { _, newValue in
                var current: [String: Int] = [:]
                for d in plan.dims { current[d.n] = d.initial }
                plan.switchDims(to: newValue, keepFrom: current)
            }
            ForEach(plan.dims.indices, id: \.self) { i in
                Stepper("\(plan.dims[i].n) 初值 \(plan.dims[i].initial)",
                        value: $plan.dims[i].initial, in: 0...100, step: 5)
            }
        } header: {
            Text("关系维度（状态档用）")
        }
    }

    // MARK: 规则覆盖

    private var rulesSection: some View {
        Section {
            Toggle("整本替换内置写手规则", isOn: $showRulesEditor)
            if showRulesEditor {
                TextEditor(text: $plan.rulesOverride)
                    .font(.caption)
                    .frame(minHeight: 180)
                HStack {
                    Button("填入母版原文") {
                        plan.rulesOverride = ContentKit.writerRulesRaw
                    }
                    .buttonStyle(.bordered)
                    Button("清空（用内置）") {
                        plan.rulesOverride = ""
                        showRulesEditor = false
                    }
                    .buttonStyle(.bordered)
                }
                Text("母版占位符：\(ContentKit.perspectiveToken) / {{tone}} / {{targetChars}}，保存时按当前设置替换。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("写手规则（18 条）")
        } footer: {
            Text("内置模板来自小说机母版，写着「读者是成年人，内容不作删减」与对话不绕开性的纪律；改这里只影响本书。")
                .font(.caption2)
        }
    }

    // MARK: 全书指令

    private var instructionSection: some View {
        Section {
            TextEditor(text: $plan.remakeInstruction)
                .font(.caption)
                .frame(minHeight: 80)
        } header: {
            Text("全书重制 / 生成总指令")
        } footer: {
            Text("每一章都会带上这段（在规则与基调之后）。单章指令优先于它。")
                .font(.caption2)
        }
    }

    // MARK: 底部

    private var footerSection: some View {
        Section {
            Text(plan.summaryLine).font(.caption).foregroundStyle(.secondary)
            Button("预览当前写手规则") {
                showRulesEditor = true
            }
            .font(.caption)
        }
    }

    // MARK: 动作

    private func loadPlan() {
        guard !loaded else { return }
        plan = ContentPlan.load(from: project)
        if !plan.rulesOverride.isEmpty { showRulesEditor = true }
        if plan.levelExplicitlySet, let p = ContentKit.tonePresets.first(where: {
            !plan.tone.isEmpty && plan.tone == $0.tone
        }) {
            presetName = p.name
        }
        loaded = true
    }

    private func save() {
        plan.apply(to: project)
        try? context.save()
        SettingsStore.shared.haptic()
        dismiss()
    }
}
