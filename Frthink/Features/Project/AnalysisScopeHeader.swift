import SwiftUI
import SwiftData

/// 分析作用范围的一行头（人物/语料/事件/规则四个面板共用）。
/// 语义：锚前正文 · 最近 N 章。值全局共享（AnalysisScope），这里只是展示与快捷调整，
/// 不再是每个面板各自持有的"范围"。
struct AnalysisScopeHeader: View {
    @Bindable var project: BookProject
    var onChange: () -> Void = {}

    @State private var tick = 0

    var body: some View {
        HStack(spacing: 8) {
            Text("作用范围：\(AnalysisScope.label(for: project))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .id(tick)
            Spacer()
            Menu {
                ForEach(AnalysisScope.chapterOptions, id: \.self) { n in
                    Button(AnalysisScope.limitLabel(n)) {
                        AnalysisScope.setChapterLimit(n, for: project)
                        tick += 1
                        onChange()
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.caption)
            }
        }
    }
}
