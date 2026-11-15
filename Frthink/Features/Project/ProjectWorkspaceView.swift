import SwiftUI
import SwiftData

/// 项目工作台：书稿 / 续写 / 功能区（三个页签，酒馆式：主场景 + 面板）。
/// 重要：所有导航栏按钮统一声明在本层（按当前页签条件显示）。
/// iOS 17 在外层已声明 .toolbar 时，TabView 子视图里的导航栏工具条项会被静默丢弃，
/// 所以子视图只保留键盘工具条与内部 sheet，导航栏入口全部在这里。
struct ProjectWorkspaceView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context

    private enum Tab: Hashable { case manuscript, write, archive }
    @State private var section: Tab = .manuscript

    // 书稿
    @State private var showImporter = false
    @State private var showFindReplace = false
    @State private var showAnchor = false
    @State private var showPromptPreview = false
    @State private var findText = ""
    @State private var replaceText = ""
    // 功能区定位请求（向导 / 菜单可以把用户直接送到某个分区）
    @State private var archiveRequest: ArchivePane?
    // ··· 菜单二级页
    @State private var showTranslation = false
    @State private var showSnapshots = false
    @State private var showHelp = false
    @State private var showStudio = false
    @State private var showContentPlan = false
    @State private var showPromptStudio = false
    @State private var showDirectory = false

    var body: some View {
        TabView(selection: $section) {
            ManuscriptEditorView(project: project, importer: $showImporter,
                                 findReplace: $showFindReplace, anchorSheet: $showAnchor,
                                 promptPreview: $showPromptPreview)
                .tabItem { Label("书稿", systemImage: "doc.text") }
                .tag(Tab.manuscript)
            ChatView(project: project)
                .tabItem { Label("续写", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.write)
            ArchiveView(project: project, requestPane: $archiveRequest)
                .tabItem { Label("功能区", systemImage: "square.grid.2x2") }
                .tag(Tab.archive)
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if section == .manuscript {
                    Button { showImporter = true } label: {
                        Label("导入正文", systemImage: "square.and.arrow.down")
                    }
                    Button { showDirectory = true } label: {
                        Label("目录", systemImage: "list.bullet.indent")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if section == .manuscript {
                    Button { showStudio = true } label: {
                        Label("准备", systemImage: "checklist")
                    }
                    Button("续写") { showPromptPreview = true }
                }
                Menu {
                    Button("提示词编排", systemImage: "list.number") { showPromptStudio = true }
                    Button("基调与尺度", systemImage: "text.book.closed") { showContentPlan = true }
                    Divider()
                    Button("翻译（逐段导出）", systemImage: "character.book.closed") { showTranslation = true }
                    Button("快照（正文版本备份）", systemImage: "clock.arrow.circlepath") { showSnapshots = true }
                    Button("保存快照", systemImage: "plus.square.on.square") { saveSnapshot() }
                    Button("导出书项目 (.json)", systemImage: "square.and.arrow.up") { export() }
                    Divider()
                    Button("查找与替换", systemImage: "magnifyingglass") { showFindReplace = true }
                    Button("使用教程", systemImage: "questionmark.circle") { showHelp = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // 书稿
        .sheet(isPresented: $showImporter) { importSheet }
        .sheet(isPresented: $showFindReplace) { findReplaceSheet }
        .sheet(isPresented: $showAnchor) { AnchorSheet(project: project) }
        .sheet(isPresented: $showDirectory) { ChapterDirectorySheet(project: project, anchorSheet: $showAnchor) }
        .fullScreenCover(isPresented: $showPromptPreview) {
            ModalPage { ContinuationSheet(project: project) }
        }
        // 准备向导
        .fullScreenCover(isPresented: $showStudio) {
            ModalPage {
                SetupWizardView(project: project,
                                onImport: { openFromWizard { showImporter = true } },
                                onOrganize: { openFromWizard { section = .archive; archiveRequest = .character } },
                                onCorpus: { openFromWizard { section = .archive; archiveRequest = .setting } },
                                onRules: { openFromWizard { section = .archive; archiveRequest = .style } },
                                onContentPlan: { openFromWizard { showContentPlan = true } },
                                onContinue: { openFromWizard { showPromptPreview = true } })
            }
        }
        .fullScreenCover(isPresented: $showContentPlan) { ModalPage { ContentPlanEditor(project: project) } }
        .fullScreenCover(isPresented: $showPromptStudio) { ModalPage { PromptStudioView(project: project) } }
        .fullScreenCover(isPresented: $showTranslation) { ModalPage { TranslationView(project: project) } }
        .fullScreenCover(isPresented: $showSnapshots) { ModalPage { SnapshotsView(project: project) } }
        .fullScreenCover(isPresented: $showHelp) { ModalPage { HelpView() } }
        .onDisappear { try? context.save() }
    }

    // MARK: ··· 菜单动作

    /// 向导内的二级入口：先关向导再开目标（避免 fullScreenCover 叠层冲突）
    private func openFromWizard(_ action: @escaping () -> Void) {
        showStudio = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
    }

    private func saveSnapshot() {
        context.insert(BodySnapshot(project: project, label: "手动快照", body: project.body))
        project.revision += 1
        try? context.save()
        SettingsStore.shared.haptic()
    }

    private func export() {
        let data = ArchiveService.export(project: project, context: context)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("书项目-\(project.title).json")
        try? data.write(to: url)
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.present(share, animated: true)
    }

    // MARK: 书稿面板（查找替换 / 章节导航 / 导入正文）

    private var findReplaceSheet: some View {
        NavigationStack {
            Form {
                TextField("查找", text: $findText)
                TextField("替换为", text: $replaceText)
                Button("全部替换") {
                    if !findText.isEmpty {
                        project.body = project.body.replacingOccurrences(of: findText, with: replaceText)
                        try? context.save()
                    }
                }
                .disabled(findText.isEmpty)
                let count = findText.isEmpty ? 0 : project.body.components(separatedBy: findText).count - 1
                Text(count > 0 ? "找到 \(count) 处" : "没有找到")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("查找与替换")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showFindReplace = false } } }
        }
        .presentationDetents([.medium])
    }

    private var importSheet: some View {
        TextImportSheet(
            onReplace: { text in
                let snap = BodySnapshot(project: project, label: "导入前备份", body: project.body)
                context.insert(snap)
                project.body = text
                project.updatedAt = .now
                project.anchorOffset = nil
                try? context.save()
                SettingsStore.shared.haptic()
            },
            onAppend: { text in
                let snap = BodySnapshot(project: project, label: "追加前备份", body: project.body)
                context.insert(snap)
                project.body += (project.body.isEmpty || project.body.hasSuffix("\n") ? "" : "\n") + text
                project.updatedAt = .now
                try? context.save()
                SettingsStore.shared.haptic()
            })
    }
}

/// 全屏二级页容器：自带导航栈 + 右上角「完成」关闭（翻译 / 规则 / 快照 / 教程）
struct ModalPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}
