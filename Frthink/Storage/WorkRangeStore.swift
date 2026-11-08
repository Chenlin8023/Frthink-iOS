import Foundation
import SwiftUI
import SwiftData

// MARK: - 工作范围（对应安卓: 分段处理的目标区间 + 章节导航定位）
// 流水线：选定范围 → 人物 → 语料/事件/文风 → 梗概+规范+尾部+续写大纲
// 按项目存 UserDefaults（避免 SwiftData schema 迁移风险）

struct WorkRange: Equatable {
    var start: Int
    var end: Int   // 处理 body[start..<end]
}

enum WorkRangeStore {

    private static func key(_ id: UUID) -> String { "workrange.\(id.uuidString)" }

    static func range(for project: BookProject) -> WorkRange? {
        guard let s = UserDefaults.standard.string(forKey: key(project.id)) else { return nil }
        let parts = s.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 0, parts[0] < parts[1], parts[1] <= project.body.count else {
            return nil
        }
        return WorkRange(start: parts[0], end: parts[1])
    }

    static func set(_ range: WorkRange?, for project: BookProject) {
        if let r = range {
            UserDefaults.standard.set("\(r.start),\(r.end)", forKey: key(project.id))
        } else {
            UserDefaults.standard.removeObject(forKey: key(project.id))
        }
    }

    private static func substring(_ project: BookProject, _ r: WorkRange) -> String {
        let clampedStart = min(r.start, project.body.count)
        let s = project.body.index(project.body.startIndex, offsetBy: clampedStart)
        let e = project.body.index(s, offsetBy: min(max(r.end - clampedStart, 0),
                                                    project.body.count - clampedStart))
        return String(project.body[s..<e])
    }

    /// 人物整理用：设了范围=范围内文本；否则全书
    static func text(for project: BookProject) -> String {
        if let r = range(for: project) { return substring(project, r) }
        return project.body
    }

    /// 语料/事件/文风用：设了范围=范围内文本；否则按原逻辑取尾部
    static func analysisText(for project: BookProject, fallbackSuffix: Int) -> String {
        if let r = range(for: project) { return substring(project, r) }
        return String(project.body.suffix(fallbackSuffix))
    }

    /// 展示用标签："全文" / "第 N–M 字（第X章）"
    static func label(for project: BookProject) -> String {
        guard let r = range(for: project) else { return "全文" }
        let chapters = PromptBuilder.chapterRanges(in: project.body)
        let ch = chapters.last(where: { $0.offset <= r.start })
        return ch.map { "第 \(r.start)–\(r.end) 字（\($0.title.prefix(24))）" }
            ?? "第 \(r.start)–\(r.end) 字"
    }
}

/// 工作范围选择器（章节列表点击即选中该章为分析范围）
struct WorkRangePickerSheet: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var customStart = ""
    @State private var customEnd = ""
    @State private var tick = 0

    private var chapters: [(title: String, offset: Int)] {
        PromptBuilder.chapterRanges(in: project.body)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("全文（人物整理=全书分段；其余=正文尾部）") {
                        WorkRangeStore.set(nil, for: project)
                        tick += 1
                    }
                } header: {
                    Text("当前：\(WorkRangeStore.label(for: project))")
                }
                Section("按章节设定分析范围（点击章节即选中）") {
                    if chapters.isEmpty {
                        Text("没有识别到章节标题").foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(Array(chapters.enumerated()), id: \.offset) { i, ch in
                        let end = i + 1 < chapters.count ? chapters[i + 1].offset : project.body.count
                        Button {
                            WorkRangeStore.set(WorkRange(start: ch.offset, end: end), for: project)
                            tick += 1
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ch.title)
                                Text("第 \(ch.offset)–\(end) 字 · 约 \(end - ch.offset) 字")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("自定义范围（字符偏移）") {
                    HStack {
                        TextField("起始", text: $customStart).keyboardType(.numberPad)
                        Text("–")
                        TextField("结束", text: $customEnd).keyboardType(.numberPad)
                        Button("设定") {
                            if let s = Int(customStart), let e = Int(customEnd),
                               s >= 0, s < e, e <= project.body.count {
                                WorkRangeStore.set(WorkRange(start: s, end: e), for: project)
                                tick += 1
                            }
                        }
                    }
                }
                Section {
                    Button("将续写锚设为范围末尾（分析完就从这里续写）") {
                        if let r = WorkRangeStore.range(for: project) {
                            project.anchorOffset = r.end
                            try? context.save()
                            dismiss()
                        }
                    }
                    .disabled(WorkRangeStore.range(for: project) == nil)
                } footer: {
                    Text("「续写」始终从锚点（或正文结尾）之后开始生成")
                }
            }
            .navigationTitle("工作范围")
            .id(tick)
        }
    }
}
