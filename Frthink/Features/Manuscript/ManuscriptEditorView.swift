import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreFoundation

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
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showImporter = true
                } label: {
                    Label("导入正文", systemImage: "square.and.arrow.down")
                }
            }
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

    // MARK: 导入正文（.txt / .md，GBK 与 UTF-8 双编码，替换或追加）
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

/// 文本文件导入器（对应 Android: 导入正文，文件≤300MiB，导入预览）
struct TextImportSheet: View {
    let onReplace: (String) -> Void
    let onAppend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var error: String?
    @State private var preview: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let preview {
                    VStack(spacing: 6) {
                        Text("预览（前 1200 字，共 \(preview.count) 字）")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView { Text(preview.prefix(1200)).font(.caption).padding() }
                    }
                    VStack(spacing: 10) {
                        Button("替换正文（原正文自动备份为快照）") {
                            onReplace(preview); dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("追加到正文末尾") {
                            onAppend(preview); dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    ContentUnavailableView("导入正文", systemImage: "doc.badge.plus",
                                           description: Text("支持 .txt / .md 纯文本文件\n自动识别 UTF-8 与 GBK（GB18030）编码"))
                    Button("选择文件") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .padding()
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "md") ?? .text]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    if size > 300 * 1024 * 1024 {
                        error = "文件超过 300 MiB"
                        return
                    }
                    let data = try Data(contentsOf: url)
                    guard let text = Self.decode(data) else {
                        error = "无法识别文件编码（已尝试 UTF-8 / GB18030）"
                        return
                    }
                    preview = text
                } catch {
                    self.error = "读取失败：\(error.localizedDescription)"
                }
            }
            .navigationTitle("导入正文")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if preview != nil {
                        Button("重新选择") { preview = nil; showImporter = true }
                    }
                }
            }
        }
    }

    /// UTF-8 优先，失败回退 GB18030（Windows 记事本导出的中文小说常见 GBK）
    static func decode(_ data: Data) -> String? {
        var d = data
        // 去 BOM
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d.removeFirst(3) }
        if d.starts(with: [0xFF, 0xFE]) { return String(data: d, encoding: .utf16LittleEndian) }
        if d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16BigEndian) }
        if let s = String(data: d, encoding: .utf8) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: d, encoding: gb) { return s }
        return nil
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
