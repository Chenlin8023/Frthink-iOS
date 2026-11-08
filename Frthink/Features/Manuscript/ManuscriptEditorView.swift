import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 书稿编辑器（对应 Android: WebView+CodeMirror 编辑器、续写锚、查找替换、章节导航、导入正文）
struct ManuscriptEditorView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme

    @State private var showFindReplace = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var showChapterNav = false
    @State private var showImporter = false
    @State private var showPromptPreview = false
    @State private var lastSaved = Date.now

    var body: some View {
        VStack(spacing: 0) {
            // 锚点状态条
            if let anchor = project.anchorOffset {
                HStack(spacing: 8) {
                    Image(systemName: "anchor")
                        .font(.caption)
                    Text("续写锚：第 \(anchor) 字处")
                        .font(.caption)
                    Spacer()
                    Button("取消锚") { project.anchorOffset = nil; try? context.save() }
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
            }

            EditorTextEditor(text: $project.body)
                .padding(8)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            // 底部状态栏
            HStack(spacing: 14) {
                Text("\(project.wordCount) 字").monospacedDigit()
                if project.anchorOffset == nil {
                    Button {
                        project.anchorOffset = project.body.count
                        try? context.save()
                        SettingsStore.shared.haptic()
                    } label: {
                        Label("放置续写锚", systemImage: "anchor")
                    }
                }
                Spacer()
                Text("已保存 \(lastSaved.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    showFindReplace = true
                } label: { Image(systemName: "magnifyingglass") }
                Button {
                    showChapterNav = true
                } label: { Image(systemName: "list.bullet.indent") }
                Button {
                    project.bookmarkOffset = project.body.count
                    try? context.save()
                } label: { Image(systemName: "bookmark") }
                Button {
                    showImporter = true
                } label: { Image(systemName: "square.and.arrow.down") }
                Spacer()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("续写") { showPromptPreview = true }
                    .disabled(project.body.isEmpty)
            }
        }
        .sheet(isPresented: $showFindReplace) { findReplaceSheet }
        .sheet(isPresented: $showChapterNav) { chapterNavSheet }
        .sheet(isPresented: $showImporter) { importSheet }
        .sheet(isPresented: $showPromptPreview) {
            ContinuationSheet(project: project)
        }
        .onChange(of: project.body) { _, _ in
            lastSaved = .now
            if UInt.random(in: 0..<8) == 0 { try? context.save() } // 节流自动保存
        }
        .onDisappear { try? context.save() }
    }

    // MARK: 查找与替换
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

    // MARK: 章节导航
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

    // MARK: 导入正文（.txt / .md）
    private var importSheet: some View {
        TextImportSheet { text in
            let snap = BodySnapshot(project: project, label: "导入前备份", body: project.body)
            context.insert(snap)
            project.body = text
            project.updatedAt = .now
            try? context.save()
        }
    }
}

/// 文本文件导入器（对应 Android: 导入正文，文件≤300MiB）
struct TextImportSheet: View {
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var error: String?
    @State private var preview: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let preview {
                    ScrollView { Text(preview.prefix(1200)).font(.caption).padding() }
                    Button("替换正文（原正文会先备份为快照）") {
                        onImport(preview)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ContentUnavailableView("导入正文", systemImage: "doc.badge.plus",
                                           description: Text("支持 .txt / .md 纯文本文件"))
                    Button("选择文件") { showImporter = true }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "md") ?? .text]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    if size > 300 * 1024 * 1024 {
                        error = "文件超过 300 MiB"
                        return
                    }
                    preview = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    self.error = "读取失败：\(error.localizedDescription)"
                }
            }
            .navigationTitle("导入正文")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

/// 编辑器文本视图（轻量封装，便于后续替换为富文本/CodeMirror 方案）
struct EditorTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 16, design: .serif))
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .autocorrectionDisabled(false)
    }
}
