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
    @State private var query = ""
    @State private var jumpChapter = ""
    @State private var limit: Int = AnalysisScope.defaultChapters
    @State private var tick = 0

    private var scan: (chapters: [ChapterNode], volumes: [VolumeNode]) {
        ChapterIndex.scan(project.body)
    }

    private var filtered: [ChapterNode] {
        ChapterIndex.filter(scan.chapters, query: query)
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
                searchSection
                chapterSections
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

    // MARK: 搜索与快跳

    private var searchSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("搜索章节标题", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                TextField("跳到第 N 章", text: $jumpChapter)
                    .keyboardType(.numberPad)
                    .frame(width: 110)
                Button("跳到并设锚") { jumpToChapter() }
                    .font(.caption)
                    .disabled(Int(jumpChapter) == nil)
                Spacer()
            }
            HStack(spacing: 8) {
                Button("首章") { setAnchor(scan.chapters.first?.start) }
                    .font(.caption)
                Button("末章") { setAnchor(scan.chapters.last?.start) }
                    .font(.caption)
                if let c = currentChapter {
                    Button("锚所在章") { setAnchor(c.start) }
                        .font(.caption)
                }
                Spacer()
            }
            .buttonStyle(.bordered)
        } header: {
            Text("定位")
        } footer: {
            if !query.isEmpty {
                Text("匹配 \(filtered.count) 章")
                    .font(.caption2)
            }
        }
    }

    // MARK: 目录

    @ViewBuilder
    private var chapterSections: some View {
        if scan.chapters.isEmpty {
            Section("目录") {
                Text("没有识别到章节标题（支持「第X章 / 序章 / 楔子 / 尾声 / 番外 / Chapter N」）。可以手动填偏移，或选「锚到正文末尾」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if !query.isEmpty || scan.volumes.isEmpty {
            Section("章节（\(filtered.count)）") {
                ForEach(filtered) { node in
                    chapterRow(node)
                }
            }
        } else {
            ForEach(scan.volumes) { v in
                Section(volumeHeader(v)) {
                    ForEach(nodes(in: v)) { node in
                        chapterRow(node)
                    }
                }
            }
        }
    }

    private func volumeHeader(_ v: VolumeNode) -> String {
        let count = nodes(in: v).count
        return "\(v.title)（\(count) 章）"
    }

    private func nodes(in volume: VolumeNode) -> [ChapterNode] {
        scan.chapters.filter { $0.start >= volume.start && $0.start < volume.end }
    }

    private func chapterRow(_ node: ChapterNode) -> some View {
        Button {
            setAnchor(node.start)
        } label: {
            HStack(spacing: 8) {
                Text("\(node.index)")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.title).font(.footnote).lineLimit(1)
                    Text("第 \(node.start) 字 · 约 \(node.chars) 字")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if node.start == anchor {
                    Image(systemName: "anchor.fill").font(.caption2).foregroundStyle(.tint)
                }
            }
        }
        .tint(.primary)
        .contextMenu {
            Button("设锚到本章开头") { setAnchor(node.start) }
            Button("设锚到本章结尾") { setAnchor(node.end) }
            Button("复制标题") { UIPasteboard.general.string = node.title }
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

    private func jumpToChapter() {
        guard let n = Int(jumpChapter) else { return }
        guard let node = scan.chapters.first(where: { $0.index == n }) else { return }
        query = ""
        jumpChapter = ""
        setAnchor(node.start)
    }
}
