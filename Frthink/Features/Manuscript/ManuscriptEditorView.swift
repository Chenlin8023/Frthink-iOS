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
    @Binding var anchorSheet: Bool
    @Binding var promptPreview: Bool
    @Binding var jumpOffset: Int?
    @Environment(\.modelContext) private var context

    @State private var lastSaved = Date.now
    @State private var cachedWords = 0
    @State private var cachedChapters = 0
    @State private var cursorOffset = 0

    /// 把续写锚放到当前光标处（精细定位，不必依赖章节）
    private func setAnchorAtCursor() {
        let offset = min(max(cursorOffset, 0), project.body.count)
        project.anchorOffset = offset
        project.updatedAt = .now
        try? context.save()
        refreshDerived()
        SettingsStore.shared.haptic()
    }

    private func refreshDerived() {
        cachedWords = project.body.count
        cachedChapters = AnalysisScope.chapterCount(beforeAnchorOf: project)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 锚点状态条
            if let anchor = project.anchorOffset {
                HStack(spacing: 8) {
                    Image(systemName: "anchor")
                        .font(.caption)
                    Text("续写锚：第 \(anchor) 字 · 锚前 \(cachedChapters) 章")
                        .font(.caption)
                    Spacer()
                    Button("调整") { anchorSheet = true }
                        .font(.caption)
                    Button("取消锚") { project.anchorOffset = nil; try? context.save() }
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
            }

            EditorTextEditor(text: $project.body, jumpOffset: $jumpOffset, cursorOffset: $cursorOffset)
                .padding(8)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            // 底部状态栏
            HStack(spacing: 14) {
                Text("\(cachedWords) 字").monospacedDigit()
                Text("光标 \(cursorOffset)").monospacedDigit().foregroundStyle(.secondary)
                Button {
                    setAnchorAtCursor()
                } label: {
                    Label("在此设锚", systemImage: "anchor")
                }
                if project.anchorOffset == nil {
                    Button {
                        anchorSheet = true
                    } label: {
                        Label("按章节设锚", systemImage: "list.bullet.indent")
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
                Button { anchorSheet = true } label: { Image(systemName: "anchor") }
                Button {
                    project.bookmarkOffset = project.body.count
                    try? context.save()
                } label: { Image(systemName: "bookmark") }
                Button { importer = true } label: { Image(systemName: "square.and.arrow.down") }
                Spacer()
            }
        }
        .onAppear(perform: refreshDerived)
        .onChange(of: project.body) { _, _ in
            refreshDerived()
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

/// 正文编辑器：UIKit UITextView 包装。
/// 相对 SwiftUI TextEditor 的两点必要能力：
///   1. 按字符偏移跳转（目录点章后正文滚到该处）；
///   2. 输入防抖 —— 每敲一个字都写 SwiftData 会连带触发全书重算，十万字以上明显卡顿。
struct EditorTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var jumpOffset: Int?
    @Binding var cursorOffset: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        tv.autocorrectionType = .default
        tv.keyboardDismissMode = .interactive
        tv.delegate = context.coordinator
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        // 有未提交的输入时不要回写，否则会把用户刚敲的字覆盖成旧值
        if !context.coordinator.hasPending && tv.text != text {
            tv.text = text
        }
        guard let offset = jumpOffset else { return }
        let s = tv.text ?? ""
        let clamped = min(max(offset, 0), s.count)
        let idx = s.index(s.startIndex, offsetBy: clamped)
        let utf16Loc = s.utf16.distance(from: s.startIndex, to: idx)
        tv.scrollRangeToVisible(NSRange(location: utf16Loc, length: 0))
        DispatchQueue.main.async { self.jumpOffset = nil }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditorTextEditor
        private var pending: DispatchWorkItem?

        var hasPending: Bool { pending != nil }

        init(_ parent: EditorTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            pending?.cancel()
            let snapshot = textView.text ?? ""
            let item = DispatchWorkItem { [weak self] in
                self?.parent.text = snapshot
                self?.pending = nil
            }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            pending?.cancel()
            pending = nil
            parent.text = textView.text ?? ""

        /// 光标位置回传（Character 口径，与 anchorOffset 一致）
        func textViewDidChangeSelection(_ textView: UITextView) {
            let utf16Loc = textView.selectedRange.location
            let prefix = (textView.text as NSString).substring(to: min(utf16Loc, (textView.text as NSString).length))
            let charOffset = prefix.count
            if parent.cursorOffset != charOffset { parent.cursorOffset = charOffset }
        }
        }
    }
}
