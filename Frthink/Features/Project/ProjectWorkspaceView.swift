import SwiftUI
import SwiftData

/// 项目工作台（对应 Android: 书稿 / 对话 / 人物 / 世界 / 事件 / 快照 多入口）
struct ProjectWorkspaceView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            ManuscriptEditorView(project: project)
                .tabItem { Label("书稿", systemImage: "doc.text") }
            ChatView(project: project)
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
            CharacterCardsView(project: project)
                .tabItem { Label("人物", systemImage: "person.2") }
            WorldBookView(project: project)
                .tabItem { Label("世界", systemImage: "globe.asia.australia") }
            EventsView(project: project)
                .tabItem { Label("事件", systemImage: "list.bullet.rectangle") }
            SnapshotsView(project: project)
                .tabItem { Label("快照", systemImage: "clock.arrow.circlepath") }
        }
        .navigationTitle(project.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink { TranslationView(project: project) } label: {
                        Label("翻译", systemImage: "character.book.closed")
                    }
                    NavigationLink { RulesView(project: project) } label: {
                        Label("长期规则", systemImage: "text.badge.checkmark")
                    }
                    NavigationLink { EventsView(project: project) } label: {
                        Label("事件", systemImage: "list.bullet.rectangle")
                    }
                    Divider()
                    Button("保存快照", systemImage: "plus.square.on.square") {
                        context.insert(BodySnapshot(project: project,
                                                    label: "手动快照",
                                                    body: project.body))
                        project.revision += 1
                        try? context.save()
                    }
                    Button("导出书项目", systemImage: "square.and.arrow.up") {
                        let data = ArchiveService.export(project: project, context: context)
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("书项目-\(project.title).json")
                        try? data.write(to: url)
                        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                        UIApplication.shared.connectedScenes
                            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                            .first?.present(share, animated: true)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onDisappear { try? context.save() }
    }
}
