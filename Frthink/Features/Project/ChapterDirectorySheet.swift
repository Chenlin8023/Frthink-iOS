import SwiftUI
import SwiftData

/// 书稿页的目录：查章、跳转定位、直接设锚。
///
/// 与 AnchorSheet 的分工：目录只做「快速找到那一章」，精细定位（手动偏移、卷分组、分析范围）
/// 仍回到 AnchorSheet，避免两处都能改同一件事。
struct ChapterDirectorySheet: View {
    @Bindable var project: BookProject
    @Binding var anchorSheet: Bool
    var onJump: ((Int) -> Void)? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var scan: (chapters: [ChapterNode], volumes: [VolumeNode]) {
        ChapterIndex.scan(project.body)
    }

    private var filtered: [ChapterNode] {
        ChapterIndex.filter(scan.chapters, query: query)
    }

    private var anchor: Int { AnalysisScope.anchor(of: project) }

    private var currentChapter: ChapterNode? {
        ChapterIndex.chapter(at: anchor, in: scan.chapters)
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                chapterList
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("精细定位") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { anchorSheet = true }
                    }
                }
            }
        }
    }

    // MARK: 头部

    private var headerSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("搜索章节标题", text: $query)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            LabeledContent("全书", value: "\(scan.chapters.count) 章 · \(scan.volumes.count) 卷")
            if let c = currentChapter {
                LabeledContent("当前锚所在章", value: "第 \(c.index) 章《\(c.title)》")
                    .font(.caption)
            }
        }
    }

    // MARK: 章列表

    @ViewBuilder
    private var chapterList: some View {
        if scan.chapters.isEmpty {
            Section {
                Text("没有识别到章节标题（支持「第X章 / 序章 / 楔子 / 尾声 / 番外 / Chapter N」）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if !query.isEmpty || scan.volumes.isEmpty {
            Section("章节（\(filtered.count)）") {
                ForEach(filtered) { node in
                    row(node)
                }
            }
        } else {
            ForEach(scan.volumes) { v in
                Section("\(v.title)（\(nodes(in: v).count) 章）") {
                    ForEach(nodes(in: v)) { node in
                        row(node)
                    }
                }
            }
        }
    }

    private func nodes(in volume: VolumeNode) -> [ChapterNode] {
        scan.chapters.filter { $0.start >= volume.start && $0.start < volume.end }
    }

    private func row(_ node: ChapterNode) -> some View {
        Button {
            setAnchor(node.start)
            onJump?(node.start)
            dismiss()
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
    }

    private func setAnchor(_ offset: Int) {
        project.anchorOffset = min(max(offset, 0), project.body.count)
        project.updatedAt = .now
        try? context.save()
        SettingsStore.shared.haptic()
    }
}
