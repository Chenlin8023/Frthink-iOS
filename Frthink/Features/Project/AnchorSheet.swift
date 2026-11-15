import SwiftUI
import SwiftData

/// 续写锚（P1 起唯一坐标入口）。
/// 原来分散在「章节导航」「工作范围」「书稿页工具条」三处，现在只有这一个 sheet。
struct AnchorSheet: View {
    @Bindable var project: BookProject

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var customOffset = ""
    @State private var limit: Int = AnalysisScope.defaultChapters
    @State private var tick = 0

    private var chapters: [(title: String, offset: Int)] {
        PromptBuilder.chapterRanges(in: project.body)
    }

    private var anchor: Int { AnalysisScope.anchor(of: project) }

    private var preview: (head: String, tail: String) {
        AnalysisScope.anchorPreview(project)
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                previewSection
                chapterSection
                manualSection
                quickSection
                scopeSection
            }
            .navigationTitle("续写锚")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        AnalysisScope.setChapterLimit(limit, for: project)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                limit = AnalysisScope.chapterLimit(for: project)
            }
            .id(tick)
        }
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            LabeledContent("锚位置", value: AnalysisScope.anchorIsExplicit(project) ? "第 \(anchor) 字" : "未设（= 正文末尾）")
            LabeledContent("锚前字数", value: "\(anchor) 字")
            LabeledContent("锚前章节", value: "\(AnalysisScope.chapterCount(beforeAnchorOf: project)) 章")
            LabeledContent("正文总长", value: "\(project.body.count) 字")
        } header: {
            Text("当前锚")
        } footer: {
            Text("续写永远从锚之后开始；锚前正文用于给模型学习（尾部字数在设置里调）。")
                .font(.caption2)
        }
    }

    // MARK: 预览

    private var previewSection: some View {
        Section("锚前末尾预览") {
            if anchor == 0 {
                Text("锚在正文开头，前面没有内容。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(preview.tail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        }
    }

    // MARK: 按章节设锚

    private var chapterSection: some View {
        Section {
            if chapters.isEmpty {
                Text("没有识别到章节标题。可以在下面手动填偏移，或选「锚到正文末尾」。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(chapters.enumerated()), id: \.offset) { pair in
                    chapterRow(index: pair.offset + 1, title: pair.element.title, offset: pair.element.offset)
                }
            }
        } header: {
            Text("按章节设锚（点一行 = 从此章开头续写）")
        }
    }

    private func chapterRow(index: Int, title: String, offset: Int) -> some View {
        Button {
            project.anchorOffset = offset
            project.updatedAt = .now
            try? context.save()
            SettingsStore.shared.haptic()
            tick += 1
        } label: {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
                Text(title).font(.footnote).lineLimit(1)
                Spacer()
                if offset == anchor {
                    Image(systemName: "anchor.fill").font(.caption2).foregroundStyle(.tint)
                } else {
                    Text("第 \(offset) 字").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }

    // MARK: 手动

    private var manualSection: some View {
        Section("手动偏移") {
            HStack {
                TextField("字符偏移（0–\(project.body.count)）", text: $customOffset)
                    .keyboardType(.numberPad)
                Button("设定") {
                    if let v = Int(customOffset), v >= 0, v <= project.body.count {
                        project.anchorOffset = v
                        project.updatedAt = .now
                        try? context.save()
                        tick += 1
                    }
                }
                .disabled(Int(customOffset) == nil)
            }
        }
    }

    // MARK: 快捷

    private var quickSection: some View {
        Section {
            Button("锚到正文末尾（继续往下写）") {
                project.anchorOffset = project.body.count
                project.updatedAt = .now
                try? context.save()
                tick += 1
            }
            Button("清除锚（≡ 锚到末尾）") {
                project.anchorOffset = nil
                try? context.save()
                tick += 1
            }
        }
    }

    // MARK: 分析范围

    private var scopeSection: some View {
        Section {
            Picker("分析范围", selection: $limit) {
                ForEach(AnalysisScope.chapterOptions, id: \.self) { n in
                    Text(AnalysisScope.limitLabel(n)).tag(n)
                }
            }
            .onChange(of: limit) { _, newValue in
                AnalysisScope.setChapterLimit(newValue, for: project)
            }
            Text(AnalysisScope.label(for: project))
                .font(.caption2).foregroundStyle(.secondary)
        } header: {
            Text("分析范围（只影响人物/语料/事件/规则这类分析）")
        } footer: {
            Text("分析一律作用于锚前正文。章数越多越贵；锚前很长时建议只取最近 30 章。")
                .font(.caption2)
        }
    }
}
