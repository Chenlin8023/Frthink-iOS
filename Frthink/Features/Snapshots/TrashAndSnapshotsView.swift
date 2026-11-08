import SwiftUI
import SwiftData

/// 快照管理（对应 Android: project_snapshots / 恢复上一版）
struct SnapshotsView: View {
    @Bindable var project: BookProject
    @Environment(\.modelContext) private var context
    @State private var confirmRestore: BodySnapshot?

    var body: some View {
        List {
            if project.snapshots.isEmpty {
                ContentUnavailableView("暂无快照", systemImage: "clock.arrow.circlepath",
                                       description: Text("在工具栏「保存快照」创建；导入正文、恢复等操作会自动备份"))
            }
            ForEach(project.snapshots.sorted { $0.createdAt > $1.createdAt }) { snap in
                VStack(alignment: .leading, spacing: 4) {
                    Text(snap.label).font(.headline)
                    HStack {
                        Text(snap.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·").foregroundStyle(.secondary)
                        Text("\(snap.body.count) 字")
                        Spacer()
                        Button("恢复") { confirmRestore = snap }.font(.caption)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("删除此快照", role: .destructive) {
                        context.delete(snap); try? context.save()
                    }
                }
            }
        }
        .navigationTitle("快照")
        .alert("恢复到原文", isPresented: .init(get: { confirmRestore != nil },
                                          set: { if !$0 { confirmRestore = nil } })) {
            Button("恢复（原正文先备份）", role: .destructive) {
                if let snap = confirmRestore {
                    context.insert(BodySnapshot(project: project, label: "恢复前备份", body: project.body))
                    project.body = snap.body
                    project.updatedAt = .now
                    try? context.save()
                }
                confirmRestore = nil
            }
            Button("取消", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("当前正文会先自动备份为快照")
        }
    }
}

/// 回收站（对应 Android: trashedAt + 回收站操作）
struct TrashView: View {
    @Environment(\.modelContext) private var context
    @Query private var all: [BookProject]
    @State private var confirmEmpty = false

    private var trashed: [BookProject] {
        all.filter { $0.isTrashed }.sorted { $0.trashedAt ?? .now > $1.trashedAt ?? .now }
    }

    var body: some View {
        List {
            if trashed.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash")
            }
            ForEach(trashed) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.title)
                        Text("移入于 \((p.trashedAt ?? .now).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复") {
                        p.trashedAt = nil
                        try? context.save()
                    }
                    Button("彻底删除", role: .destructive) {
                        purge(p)
                        try? context.save()
                    }
                }
            }
        }
        .navigationTitle("回收站")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空回收站", role: .destructive) { confirmEmpty = true }
                    .disabled(trashed.isEmpty)
            }
        }
        .confirmationDialog("全部项目将永久删除，且无法恢复", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("彻底删除全部", role: .destructive) {
                for p in trashed { purge(p) }
                try? context.save()
            }
        }
    }

    /// 永久删除项目及其关联数据（对应 Android: 删除墓碑 → 清理）
    private func purge(_ p: BookProject) {
        // 关联集合（WorldEntry/CorpusEntry/WritingRule 无 cascade 关系，手动清理）
        for e in ProjectData.worldEntries(p, context: context) { context.delete(e) }
        for c in ProjectData.corpusEntries(p, context: context) { context.delete(c) }
        for r in (try? context.fetch(FetchDescriptor<WritingRule>())) ?? [] where r.project == p {
            context.delete(r)
        }
        // 级联：messages / characterCards / events / snapshots
        context.delete(p)
    }
}
