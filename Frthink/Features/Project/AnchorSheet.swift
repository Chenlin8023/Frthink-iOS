import SwiftUI
import SwiftData

/// 续写锚（唯一坐标入口）+ 小说目录。
///
/// P1.1：原来只是把章标题平铺在 Form 里，几百章滚不动。
/// 现在按 ChapterIndex 建「卷 → 章」树，带搜索、章节字数、快速跳转（首/末/锚所在/第 N 章）。
struct AnchorSheet: View {
    @Bindable var project: BookProject

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var customOffset = ""
    @State private var limit: Int = AnalysisScope.defaultChapters
    @State private var tick = 0

    private var scan: (chapters: [ChapterNode], volumes: [VolumeNode]) {
        ChapterIndex.scan(project.body)
    }


    private var anchor: Int { AnalysisScope.anchor(of: project) }

    private var preview: (head: String, tail: String) {
        AnalysisScope.anchorPreview(project)
    }

    private var currentChapter: ChapterNode? {
        ChapterIndex.chapter(at: anchor, in: scan.chapters)
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                previewSection
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
            LabeledContent("锚前", value: "\(anchor) 字 · \(AnalysisScope.chapterCount(beforeAnchorOf: project)) 章")
            if let c = currentChapter {
                LabeledContent("锚所在章", value: "第 \(c.index) 章《\(c.title)》")
            }
            LabeledContent("目录", value: "\(scan.chapters.count) 章 · \(scan.volumes.count) 卷")
        } header: {
            Text("当前锚")
        } footer: {
            Text("续写永远从锚之后开始；锚前正文用于给模型学习（尾部字数在设置里调）。")
                .font(.caption2)
        }
    }

    private var previewSection: some View {
        Section("锚前末尾预览") {
            if anchor == 0 {
                Text("锚在正文开头，前面没有内容。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(preview.tail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 手动 / 快捷 / 范围

    private var manualSection: some View {
        Section("手动偏移") {
            HStack {
                TextField("字符偏移（0–\(project.body.count)）", text: $customOffset)
                    .keyboardType(.numberPad)
                Button("设定") {
                    if let v = Int(customOffset), v >= 0, v <= project.body.count {
                        setAnchor(v)
                    }
                }
                .disabled(Int(customOffset) == nil)
            }
        }
    }

    private var quickSection: some View {
        Section {
            Button("锚到正文末尾（继续往下写）") {
                setAnchor(project.body.count)
            }
            Button("清除锚（≡ 锚到末尾）") {
                project.anchorOffset = nil
                try? context.save()
                tick += 1
            }
        }
    }

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

    // MARK: 动作

    private func setAnchor(_ offset: Int?) {
        guard let offset else { return }
        project.anchorOffset = min(max(offset, 0), project.body.count)
        project.updatedAt = .now
        try? context.save()
        SettingsStore.shared.haptic()
        tick += 1
    }

}
