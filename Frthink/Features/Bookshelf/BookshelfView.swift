import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 我的书架（对应 Android: 书架/项目管理）
struct BookshelfView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<BookProject> { $0.trashedAt == nil },
           sort: \BookProject.updatedAt, order: .reverse)
    private var projects: [BookProject]

    @State private var searchText = ""
    @State private var showNewSheet = false
    @State private var newTitle = ""
    @State private var newSynopsis = ""
    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        // 根栈由 RootView 提供（避免与工作台 TabView 叠成双层标签栏）
        Group {
                if filtered.isEmpty {
                    ContentUnavailableView("暂无项目", systemImage: "books.vertical",
                                           description: Text("点按右上角 + 新建书目\n使用教程在「设置」页顶部"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                            ForEach(filtered) { p in
                                NavigationLink {
                                    ProjectWorkspaceView(project: p)
                                } label: {
                                    BookCoverCard(project: p)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Divider()
                                    Button("创建分支", systemImage: "git-branch-create") {
                                        branch(of: p)
                                    }
                                    Button("导出书项目", systemImage: "square.and.arrow.up") {
                                        exportOne(p)
                                    }
                                    Button("移入回收站", systemImage: "trash", role: .destructive) {
                                        p.trashedAt = .now
                                        try? context.save()
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("我的书架")
            .searchable(text: $searchText, prompt: "搜索书名")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    NavigationLink { TrashView() } label: { Image(systemName: "trash") }
                    Menu {
                        Button("新建书目", systemImage: "plus.circle") { showNewSheet = true }
                        Button("导入存档 (.json)", systemImage: "square.and.arrow.down") { showImporter = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewSheet) { newProjectSheet }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                importArchive(result)
            }
            .alert("导入结果", isPresented: .init(get: { importMessage != nil }, set: { _ in importMessage = nil })) {
                Button("好", role: .cancel) {}
            } message: { Text(importMessage ?? "") }
    }

    private var filtered: [BookProject] {
        searchText.isEmpty ? projects
            : projects.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var newProjectSheet: some View {
        NavigationStack {
            Form {
                TextField("书名", text: $newTitle)
                TextField("剧情梗概（可选）", text: $newSynopsis, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle("新建书目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showNewSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建并进入") {
                        let p = BookProject(title: newTitle.isEmpty ? "未命名项目" : newTitle,
                                            synopsis: newSynopsis)
                        context.insert(p)
                        try? context.save()
                        showNewSheet = false
                        newTitle = ""; newSynopsis = ""
                        SettingsStore.shared.haptic()
                    }
                    .disabled(newTitle.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func branch(of p: BookProject) {
        let b = BookProject(title: p.title + "（分支）", synopsis: p.synopsis, genre: p.genre)
        b.body = p.body
        b.branchRootId = p.id
        context.insert(b)
        try? context.save()
    }

    private func exportOne(_ p: BookProject) {
        let data = ArchiveService.export(project: p, context: context)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("书项目-\(p.title).json")
        try? data.write(to: url)
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.present(share, animated: true)
    }

    private func importArchive(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let n = ArchiveService.importArchive(data, into: context)
            importMessage = n > 0 ? "已导入 \(n) 个项目" : "无法读取（格式不支持）"
        } catch {
            importMessage = "读取失败：\(error.localizedDescription)"
        }
    }
}

/// 书籍封面卡片
struct BookCoverCard: View {
    let project: BookProject

    private let palette: [Color] = [.indigo, .teal, .orange, .pink, .purple,
                                    .blue, .green, .red, .brown, .cyan]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(palette[project.coverColorSeed % palette.count].gradient)
                Text(String(project.title.prefix(2)))
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
            }
            .aspectRatio(3/4, contentMode: .fit)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).lineLimit(1).font(.subheadline.weight(.semibold))
                Text("\(project.wordCount) 字")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
