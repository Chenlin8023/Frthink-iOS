import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreFoundation

/// 书稿编辑器（对应 Android: WebView+CodeMirror 编辑器、续写锚、查找替换、章节导航、导入正文）
/// 注意：导航栏按钮（导入正文 / 续写）与相关面板由 ProjectWorkspaceView 统一声明——
/// 外层已有 .toolbar 时子视图的导航栏工具条项会被 iOS 17 丢弃；这里只保留键盘工具条。
struct ManuscriptEditorView: View {
    @Bindable var project: BookProject
    @Binding var importer: Bool
    @Binding var findReplace: Bool
    @Binding var chapterNav: Bool
    @Binding var promptPreview: Bool
    @Environment(\.modelContext) private var context

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
                Button { findReplace = true } label: { Image(systemName: "magnifyingglass") }
                Button { chapterNav = true } label: { Image(systemName: "list.bullet.indent") }
                Button {
                    project.bookmarkOffset = project.body.count
                    try? context.save()
                } label: { Image(systemName: "bookmark") }
                Button { importer = true } label: { Image(systemName: "square.and.arrow.down") }
                Spacer()
            }
        }
        .onChange(of: project.body) { _, _ in
            lastSaved = .now
            if UInt.random(in: 0..<8) == 0 { try? context.save() } // 节流自动保存
        }
        .onDisappear { try? context.save() }
    }
}

/// 文本文件导入器（对应 Android: 导入正文，文件≤300MiB，导入预览，GBK 与 UTF-8 双编码）
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
                                           description: Text("选择任意文件即可（推荐 .txt / .md）\n自动识别 UTF-8 / UTF-16 / GBK 编码"))
                    Button("选择文件") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .padding()
            // 注意：这里必须用 .data 放行——微信/QQ/网盘传出的 .txt 常被系统标记为 public.data
            // （不符合 public.plain-text），按 .plainText/.text 过滤会被文件选择器置灰无法选中
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let ext = url.pathExtension.lowercased()
                    let binaryExts: Set<String> = ["doc", "docx", "pdf", "epub", "mobi", "azw3",
                                                   "jpg", "jpeg", "png", "gif", "zip", "rar", "7z"]
                    if binaryExts.contains(ext) {
                        error = "「.\(ext)」是二进制格式，请先转成 .txt 再导入"
                        return
                    }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    if size > 300 * 1024 * 1024 {
                        error = "文件超过 300 MiB"
                        return
                    }
                    let data = try Data(contentsOf: url)
                    guard let text = Self.decode(data) else {
                        error = "无法识别文件编码（已尝试 UTF-8 / UTF-16 / GB18030）"
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

    /// UTF-8 优先；大量 0x00 字节 → 无 BOM 的 UTF-16；失败回退 GB18030（Windows 记事本导出的中文小说常见 GBK）
    static func decode(_ data: Data) -> String? {
        var d = data
        // 去 BOM
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d.removeFirst(3) }
        if d.starts(with: [0xFF, 0xFE]) { return String(data: d, encoding: .utf16LittleEndian) }
        if d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16BigEndian) }
        if let s = String(data: d, encoding: .utf8) { return s }
        let sample = d.prefix(4096)
        let zeros = sample.filter { $0 == 0 }.count
        if !sample.isEmpty && Double(zeros) / Double(sample.count) > 0.3 {
            if let s = String(data: d, encoding: .utf16LittleEndian) { return s }
            if let s = String(data: d, encoding: .utf16BigEndian) { return s }
        }
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
