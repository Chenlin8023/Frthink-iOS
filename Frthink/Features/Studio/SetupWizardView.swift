import SwiftUI
import SwiftData

/// 准备工作向导（P1 起取代「制作台」五段工作台）。
///
/// 一条主线：导入 → 定锚 → 建结构 → 压缩前文 → 本章要点。
/// 每步都有完成判据、可重做、可跳过；未落地的步骤显示"P2/P3 落地"而不是空壳入口。
struct SetupWizardView: View {
    @Bindable var project: BookProject

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allCards: [CharacterCard]
    @Query private var allRules: [WritingRule]

    // 由 ProjectWorkspaceView 提供（这些面板都在外层，向导只负责"带到"）
    var onImport: () -> Void = {}
    var onOrganize: () -> Void = {}
    var onCorpus: () -> Void = {}
    var onRules: () -> Void = {}
    var onContinue: () -> Void = {}

    @State private var showAnchor = false
    @State private var showBaseCheck = false

    // MARK: 完成判据

    private var hasBody: Bool { !project.body.isEmpty }
    private var hasAnchor: Bool { project.anchorOffset != nil }
    private var chapterCount: Int { AnalysisScope.chapterCount(beforeAnchorOf: project) }
    private var cardCount: Int { allCards.filter { $0.project == project }.count }
    private var ruleCount: Int { allRules.filter { $0.project == project }.count }
    private var hasDigest: Bool { cardCount > 0 && ruleCount > 0 }

    private var doneCount: Int {
        var n = 0
        if hasBody { n += 1 }
        if hasAnchor { n += 1 }
        if chapterCount > 0 { n += 1 }
        if hasDigest { n += 1 }
        return n
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                stepRows
                footerCard
            }
            .padding(16)
        }
        .navigationTitle("准备")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAnchor) {
            AnchorSheet(project: project)
        }
        .sheet(isPresented: $showBaseCheck) {
            StudioBaseCheckSheet(project: project)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("前期准备").font(.title3).bold()
                Spacer()
                Text("\(doneCount)/4").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: Double(doneCount), total: 4)
            Text("准备是线性的：每步做完就能进下一步，也可以跳过——跳过会让续写的上下文变薄。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: 五个步骤

    private var stepRows: some View {
        VStack(spacing: 10) {
            stepCard(n: 1, title: "导入正文",
                     detail: hasBody ? "已有 \(project.body.count) 字" : "txt / md，GBK 与 UTF-8 都可",
                     done: hasBody, available: true) { onImport() }

            stepCard(n: 2, title: "定续写锚",
                     detail: hasAnchor
                        ? "第 \(AnalysisScope.anchor(of: project)) 字 · 锚前 \(AnalysisScope.chapterCount(beforeAnchorOf: project)) 章"
                        : "未设锚（默认等于正文末尾）",
                     done: hasAnchor, available: true) { showAnchor = true }

            stepCard(n: 3, title: "建结构",
                     detail: chapterCount > 0
                        ? "锚前识别到 \(chapterCount) 章"
                        : "还没有章节目录（P2 起可改名/合并/拆分）",
                     done: chapterCount > 0, available: true) {
                showAnchor = true   // P2 前：章节列表就是结构视图
            }

            stepCard(n: 4, title: "压缩前文",
                     detail: "角色 \(cardCount) 张 · 文风规则 \(ruleCount) 条 · 参考材料在功能区可勾选（作用范围：\(AnalysisScope.limitLabel(AnalysisScope.chapterLimit(for: project)))）",
                     done: hasDigest, available: true) { onOrganize() }

            stepCard(n: 5, title: "写本章要点",
                     detail: "P3 落地：把你要写的情节要求变成锚后的本章要点（brief/tags/强度）",
                     done: false, available: false) { }
        }
    }

    private func stepCard(n: Int, title: String, detail: String,
                          done: Bool, available: Bool,
                          action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                badge(n: n, done: done, available: available)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline).bold()
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !available {
                    Text("未落地").font(.caption2).foregroundStyle(.tertiary)
                } else if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.55)
    }

    private func badge(n: Int, done: Bool, available: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Color.green.opacity(0.18) : Color(.tertiarySystemBackground))
                .frame(width: 26, height: 26)
            if done {
                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
            } else {
                Text("\(n)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .overlay(Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: 底部

    private var footerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("准备完了就往下写").font(.subheadline).bold()
            Text("续写只用锚之后的正文；锚前会带上：前情摘要、人物卡、设定、文风规则、本章要点，以及锚前尾部原文（学习用）。")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    onContinue()
                } label: {
                    Label("开始续写", systemImage: "text.append")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasBody)


            }
            Divider()
            HStack(spacing: 10) {
                Button { onCorpus() } label: { Label("语料", systemImage: "books.vertical") }
                    .buttonStyle(.bordered).font(.caption)
                Button { onRules() } label: { Label("文风规则", systemImage: "text.badge.checkmark") }
                    .buttonStyle(.bordered).font(.caption)
                Button { showBaseCheck = true } label: { Label("基座自检", systemImage: "checkmark.seal") }
                    .buttonStyle(.bordered).font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
