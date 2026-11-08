import SwiftUI
import SwiftData

/// 项目工作台（对应 Android: 书稿 / 对话 / 人物 / 世界 / 事件 + 翻译 / 规则 / 快照）
/// 重要：所有导航栏按钮统一声明在本层（按当前页签条件显示）。
/// iOS 17 在外层已声明 .toolbar 时，TabView 子视图里的导航栏工具条项会被静默丢弃，
/// 所以子视图只保留键盘工具条与内部 sheet，导航栏入口全部在这里。
struct ProjectWorkspaceView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context

    private enum Section: Hashable { case manuscript, chat, cards, world, events }
    @State private var section: Section = .manuscript

    // 书稿
    @State private var showImporter = false
    @State private var showFindReplace = false
    @State private var showChapterNav = false
    @State private var showPromptPreview = false
    @State private var findText = ""
    @State private var replaceText = ""
    // 人物
    @State private var showOrganize = false
    @State private var showNewCard = false
    // 世界
    @State private var showWorldEntryEditor = false
    @State private var showCorpus = false
    // 事件
    @State private var showExtractEvents = false
    // ··· 菜单二级页
    @State private var showTranslation = false
    @State private var showRules = false
    @State private var showSnapshots = false
    @State private var showHelp = false

    var body: some View {
        TabView(selection: $section) {
            ManuscriptEditorView(project: project, importer: $showImporter,
                                 findReplace: $showFindReplace, chapterNav: $showChapterNav,
                                 promptPreview: $showPromptPreview)
                .tabItem { Label("书稿", systemImage: "doc.text") }
                .tag(Section.manuscript)
            ChatView(project: project)
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                .tag(Section.chat)
            CharacterCardsView(project: project, organizeSheet: $showOrganize,
                               newCardRequest: $showNewCard)
                .tabItem { Label("人物", systemImage: "person.2") }
                .tag(Section.cards)
            WorldBookView(project: project, corpusSheet: $showCorpus,
                          newEntryRequest: $showWorldEntryEditor)
                .tabItem { Label("世界", systemImage: "globe.asia.australia") }
                .tag(Section.world)
            EventsView(project: project, extractSheet: $showExtractEvents)
                .tabItem { Label("事件", systemImage: "list.bullet.rectangle") }
                .tag(Section.events)
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if section == .manuscript {
                    Button { showImporter = true } label: {
                        Label("导入正文", systemImage: "square.and.arrow.down")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if section == .manuscript {
                    Button("续写") { showPromptPreview = true }
                }
                if section == .cards {
                    Button { showOrganize = true } label: {
                        Label("人物整理", systemImage: "sparkles")
                    }
                    Button { showNewCard = true } label: {
                        Label("新建人物卡", systemImage: "plus")
                    }
                }
                if section == .world {
                    Button { showCorpus = true } label: {
                        Label("语料库", systemImage: "books.vertical")
                    }
                    Button { showWorldEntryEditor = true } label: {
                        Label("新增词条", systemImage: "plus")
                    }
                }
                if section == .events {
                    Button("提取事件") { showExtractEvents = true }
                }
                Menu {
                    Button("翻译（逐段导出）", systemImage: "character.book.closed") { showTranslation = true }
                    Button("长期规则（文风归纳）", systemImage: "text.badge.checkmark") { showRules = true }
                    Button("快照（正文版本备份）", systemImage: "clock.arrow.circlepath") { showSnapshots = true }
                    Divider()
                    Button("保存快照", systemImage: "plus.square.on.square") { saveSnapshot() }
                    Button("导出书项目 (.json)", systemImage: "square.and.arrow.up") { export() }
                    Divider()
                    Button("查找与替换", systemImage: "magnifyingglass") { showFindReplace = true }
                    Button("章节导航", systemImage: "list.bullet.indent") { showChapterNav = true }
                    Divider()
                    Button("使用教程", systemImage: "questionmark.circle") { showHelp = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // 书稿
        .sheet(isPresented: $showImporter) { importSheet }
        .sheet(isPresented: $showFindReplace) { findReplaceSheet }
        .sheet(isPresented: $showChapterNav) { chapterNavSheet }
        .sheet(isPresented: $showPromptPreview) { ContinuationSheet(project: project) }
        // 人物 / 世界 / 事件
        .sheet(isPresented: $showOrganize) { CharacterOrganizeSheet(project: project) }
        .sheet(isPresented: $showNewCard) { CardEditorSheet(project: project, card: nil) }
        .sheet(isPresented: $showWorldEntryEditor) { WorldEntryEditor(project: project, entry: nil) }
        .sheet(isPresented: $showCorpus) { CorpusListView(project: project) }
        .sheet(isPresented: $showExtractEvents) { EventExtractSheet(project: project) }
        // ··· 二级页（全屏，右上角「完成」关闭）
        .fullScreenCover(isPresented: $showTranslation) { ModalPage { TranslationView(project: project) } }
        .fullScreenCover(isPresented: $showRules) { ModalPage { RulesView(project: project) } }
        .fullScreenCover(isPresented: $showSnapshots) { ModalPage { SnapshotsView(project: project) } }
        .fullScreenCover(isPresented: $showHelp) { ModalPage { HelpView() } }
        .onDisappear { try? context.save() }
    }

    // MARK: ··· 菜单动作

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

    private var chapterNavSheet: some View {
        NavigationStack {
            List {
                let chapters = PromptBuilder.chapterRanges(in: project.body)
                if chapters.isEmpty {
                    Text("没有识别到章节标题").foregroundStyle(.secondary)
                }
                ForEach(Array(chapters.enumerated()), id: \.offset) { _, ch in
                    VStack(alignment: .leading) {
                        Text(ch.title)
                        Text("第 \(ch.offset) 字 · 约 \(Int(Double(ch.offset) / max(1, Double(project.body.count)) * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("章节导航")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showChapterNav = false } } }
        }
        .presentationDetents([.large])
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
