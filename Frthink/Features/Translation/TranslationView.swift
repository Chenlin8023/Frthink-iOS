import SwiftUI
import SwiftData

/// 逐段翻译（对应 Android: translation_segments 缓存 + 只输出译文）
struct TranslationView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @State private var targetLang = "英语"
    @State private var segments: [SegmentState] = []
    @State private var running = false
    @State private var task: Task<Void, Never>?
    @State private var showExport = false

    struct SegmentState: Identifiable {
        let id: Int
        let source: String
        var translation: String = ""
        var status: String = ""   // "" | 处理中 | 完成 | 失败
        var note: String = ""     // 失败原因
        var sourceHash: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            if project.body.isEmpty {
                EmptyBodyHint().padding(.horizontal).padding(.top, 8)
            }
            HStack {
                Picker("目标语言", selection: $targetLang) {
                    ForEach(["英语", "日语", "中文", "韩语", "法语"], id: \.self) { Text($0) }
                }
                Spacer()
                if running {
                    Button("停止翻译", role: .destructive) { task?.cancel() }
                } else {
                    Button("开始翻译") { run() }.buttonStyle(.borderedProminent)
                        .disabled(project.body.isEmpty)
                }
            }
            .padding()

            List(segments) { seg in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(seg.status.isEmpty ? "待翻译" : seg.status)
                            .font(.caption2)
                            .padding(3)
                            .background(statusColor(seg.status).opacity(0.2))
                            .cornerRadius(4)
                        Spacer()
                        Text("\(seg.source.count) 字").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(seg.source).font(.caption).lineLimit(4).foregroundStyle(.secondary)
                    if !seg.translation.isEmpty {
                        Text(seg.translation).font(.subheadline)
                    }
                    if !seg.note.isEmpty {
                        Text(seg.note).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("翻译")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("导出译文") { export() }.disabled(segments.allSatisfy { $0.translation.isEmpty })
            }
        }
        .onAppear(perform: rebuild)
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "完成": return .green
        case "失败": return .red
        case "处理中": return .blue
        default: return .gray
        }
    }

    private func rebuild() {
        // sourceHash 缓存：同一段上次译文直接复用（对应 Android: translation_segments 表）
        let paras = PromptBuilder.segments(of: project.body, budget: 2500)
        segments = paras.enumerated().map { i, text in
            .init(id: i, source: text, sourceHash: text.hashValue)
        }
    }

    private func run() {
        running = true
        guard let cred0 = SettingsStore.shared.activeCredential else { running = false; return }
        var cred = cred0
        let m = SettingsStore.shared.model(for: "translation")
        if !m.isEmpty { cred.model = m }
        task = Task {
            for i in segments.indices {
                if Task.isCancelled { break }
                // 跳过已完成的段（只继续未完成部分）
                guard segments[i].status != "完成" else { continue }
                await MainActor.run { segments[i].status = "处理中" }
                let compiled = PromptBuilder.compileTranslation(segment: segments[i].source, target: targetLang)
                var acc = ""
                var ok = false
                var errNote = ""
                await withCheckedContinuation { cont in
                    _ = LlmClient.shared.stream(credential: cred, messages: compiled.messages,
                                                temperature: 0.2, maxTokens: 4096) { ev in
                        if !ev.contentDelta.isEmpty { acc += ev.contentDelta }
                        if let f = ev.finished {
                            if f.hasPrefix("error:") { ok = false; errNote = f } else { ok = true }
                            cont.resume()
                        }
                    }
                }
                await MainActor.run {
                    segments[i].translation = acc.trimmingCharacters(in: .whitespacesAndNewlines)
                    segments[i].status = ok ? "完成" : "失败"
                    segments[i].note = ok ? "" : String(errNote.prefix(160))
                }
            }
            await MainActor.run { running = false }
        }
    }

    private func export() {
        let text = segments.compactMap { $0.translation.isEmpty ? nil : $0.translation }.joined(separator: "\n\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("译文-\(project.title)-\(targetLang).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.present(share, animated: true)
    }
}
