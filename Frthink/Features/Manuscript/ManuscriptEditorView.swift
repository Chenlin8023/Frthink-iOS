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

/// 文本文件导入器（对应 Android: 导入正文，文件≤300MiB，导入预览，多编码识别 + 粘贴导入备用路径）
struct TextImportSheet: View {
    let onReplace: (String) -> Void
    let onAppend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var error: String?
    @State private var diagnostic: String?
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
                                           description: Text("选文件或直接粘贴均可（推荐 .txt / .md）\n自动识别 UTF-8 / UTF-16 / GBK 编码"))
                    Button("从文件选择…") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                    Button("粘贴剪贴板文本导入") { pasteImport() }
                        .buttonStyle(.bordered)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption).multilineTextAlignment(.center) }
                if let diagnostic {
                    Text(diagnostic)
                        .font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            // 用 UIKit 文档选择器而非 SwiftUI fileImporter——后者在 sheet 内存在 iOS 17 选完回调不触发的 bug；
            // asCopy:true 直接拿系统复制好的副本，绕开安全作用域与云占位符问题
            .sheet(isPresented: $showImporter) {
                DocumentPicker(
                    onPick: { url in
                        showImporter = false
                        handlePick(url)
                    },
                    onCancel: { showImporter = false })
            }
            .navigationTitle("导入正文")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if preview != nil {
                        Button("重新选择") { preview = nil; error = nil; diagnostic = nil }
                    }
                }
            }
        }
    }

    // MARK: 文件导入（asCopy 副本 + 二次复制到临时目录双保险，规避云占位符/第三方提供方读取问题）

    private func handlePick(_ url: URL) {
        error = nil; diagnostic = nil
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let binaryExts: Set<String> = ["doc", "docx", "pdf", "epub", "mobi", "azw3",
                                           "jpg", "jpeg", "png", "gif", "zip", "rar", "7z"]
            if binaryExts.contains(ext) {
                error = "「.\(ext)」是二进制格式，请先转成 .txt 再导入"
                diagnostic = "文件：\(url.lastPathComponent)"
                return
            }

            var data = Data()
            var readVia = ""
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString)-\(url.lastPathComponent)")
            do {
                try FileManager.default.copyItem(at: url, to: tmp)   // 再复制一层（最稳）
                data = try Data(contentsOf: tmp)
                readVia = "copy"
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                data = try Data(contentsOf: url)                     // 复制失败回退直读
                readVia = "direct"
            }

            if data.count > 300 * 1024 * 1024 {
                error = "文件超过 300 MiB"
                diagnostic = "文件：\(url.lastPathComponent) · \(data.count) 字节"
                return
            }
            guard let text = Self.decode(data) else {
                error = "无法识别文件编码（已尝试 UTF-8 / UTF-16 / GB18030）"
                diagnostic = self.diag(url, data, readVia)
                return
            }
            diagnostic = "\(diag(url, data, readVia)) · 编码已识别 ✓"
            preview = text
        } catch {
            self.error = "读取失败：\(error.localizedDescription)"
            diagnostic = diag(url, Data(), "?")
        }
    }

    private func pasteImport() {
        error = nil; diagnostic = nil
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            error = "剪贴板没有文本内容（先在别处复制正文）"
            return
        }
        diagnostic = "来源：剪贴板 · \(text.utf8.count) 字节"
        preview = text
    }

    private func diag(_ url: URL, _ data: Data, _ via: String) -> String {
        let head = data.isEmpty ? "-" : data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "文件：\(url.lastPathComponent) · \(data.count) 字节 · 读取：\(via) · 头部：\(head)"
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

/// UIKit 文档选择器封装（asCopy:true 直接返回系统复制好的文件副本）
/// 不用 SwiftUI fileImporter：其在 sheet 内存在 iOS 17 选完回调不触发的 bug
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
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
