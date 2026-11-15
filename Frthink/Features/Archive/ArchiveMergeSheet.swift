import SwiftUI
import SwiftData

/// 条目一键合并（同类去重）。
///
/// 策略保守：只把「归一化后完全相同」的条目归为一组（去空白/标点/括号内容），
/// 列出候选组让你确认；合并不是自动执行的，避免误删。
enum MergeKind: String {
    case character, setting, plot, style

    var title: String {
        switch self {
        case .character: return "角色"
        case .setting: return "设定"
        case .plot: return "剧情"
        case .style: return "文风"
        }
    }
}

struct MergeGroup: Identifiable {
    var id: String
    var names: [String]
    var ids: [UUID]
}

struct ArchiveMergeSheet: View {
    @Bindable var project: BookProject
    let kind: MergeKind

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allCards: [CharacterCard]
    @Query private var allWorld: [WorldEntry]
    @Query private var allEvents: [PlotEvent]
    @Query private var allRules: [WritingRule]

    @State private var merged = 0

    var body: some View {
        NavigationStack {
            List {
                if groups.isEmpty {
                    Section {
                        Text("没有发现可合并的重复\(kind.title)条目。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(groups) { g in
                            row(g)
                        }
                    } header: {
                        Text("\(groups.count) 组重复（共 \(groups.reduce(0) { $0 + $1.ids.count }) 条）")
                    } footer: {
                        Text("合并保留字段最全的一条，其余删除；操作前不会自动备份，建议先导出存档。")
                            .font(.caption2)
                    }
                }
                if merged > 0 {
                    Section { Text("已合并 \(merged) 组").font(.caption) }
                }
            }
            .navigationTitle("合并重复\(kind.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func row(_ g: MergeGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g.names.first ?? "（未命名）").font(.footnote).bold()
            Text(g.names.joined(separator: " / "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Button {
                performMerge(g)
            } label: {
                Label("合并这 \(g.ids.count) 条", systemImage: "arrow.triangle.merge")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    // MARK: 分组

    private var groups: [MergeGroup] {
        switch kind {
        case .character:
            return build(cards, name: { $0.name }, id: { $0.id })
        case .setting:
            return build(entries, name: { $0.title }, id: { $0.id })
        case .plot:
            return build(events, name: { $0.title }, id: { $0.id })
        case .style:
            return build(rules, name: { $0.line }, id: { $0.id })
        }
    }

    private var cards: [CharacterCard] { allCards.filter { $0.project == project } }
    private var entries: [WorldEntry] { ProjectData.worldEntries(project, context: context) }
    private var events: [PlotEvent] { allEvents.filter { $0.project == project } }
    private var rules: [WritingRule] { allRules.filter { $0.project == project } }

    private func build<T>(_ items: [T], name: (T) -> String, id: (T) -> UUID) -> [MergeGroup] {
        var buckets: [String: [(String, UUID)]] = [:]
        for it in items {
            let key = Self.normalize(name(it))
            if key.isEmpty { continue }
            buckets[key, default: []].append((name(it), id(it)))
        }
        return buckets
            .filter { $0.value.count >= 2 }
            .map { MergeGroup(id: $0.key, names: $0.value.map(\.0), ids: $0.value.map(\.1)) }
            .sorted { $0.ids.count > $1.ids.count }
    }

    /// 去空白 / 标点 / 括号内容，统一全半角
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        if let r = t.range(of: "\\([^)]*\\)", options: .regularExpression) {
            t.removeSubrange(r)
        }
        let drop = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
            .union(.symbols)
        let kept = t.unicodeScalars.filter { !drop.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    // MARK: 合并

    private func performMerge(_ g: MergeGroup) {
        switch kind {
        case .character: mergeCards(g)
        case .setting: mergeEntries(g)
        case .plot: mergeEvents(g)
        case .style: mergeRules(g)
        }
        merged += 1
        try? context.save()
        SettingsStore.shared.haptic()
    }

    private func mergeCards(_ g: MergeGroup) {
        let items = cards.filter { g.ids.contains($0.id) }
        guard let target = items.first else { return }
        for other in items.dropFirst() {
            target.aliases = mergeText(target.aliases, other.aliases)
            target.identity = longer(target.identity, other.identity)
            target.goals = longer(target.goals, other.goals)
            target.personality = longer(target.personality, other.personality)
            target.speech = longer(target.speech, other.speech)
            target.boundaries = longer(target.boundaries, other.boundaries)
            target.memories = longer(target.memories, other.memories)
            target.attitudes = longer(target.attitudes, other.attitudes)
            target.enabled = target.enabled || other.enabled
            context.delete(other)
        }
        target.updatedAt = .now
    }

    private func mergeEntries(_ g: MergeGroup) {
        let items = entries.filter { g.ids.contains($0.id) }
        guard let target = items.first else { return }
        for other in items.dropFirst() {
            if other.content.count > target.content.count { target.content = other.content }
            target.keywords = mergeText(target.keywords, other.keywords)
            target.enabled = target.enabled || other.enabled
            context.delete(other)
        }
    }

    private func mergeEvents(_ g: MergeGroup) {
        let items = events.filter { g.ids.contains($0.id) }
        guard let target = items.first else { return }
        for other in items.dropFirst() {
            target.cause = longer(target.cause, other.cause)
            target.development = longer(target.development, other.development)
            target.result = longer(target.result, other.result)
            context.delete(other)
        }
    }

    private func mergeRules(_ g: MergeGroup) {
        let items = rules.filter { g.ids.contains($0.id) }
        guard let target = items.first else { return }
        for other in items.dropFirst() {
            if other.line.count > target.line.count { target.line = other.line }
            context.delete(other)
        }
    }

    // MARK: 字段合并工具

    private func longer(_ a: String, _ b: String) -> String {
        b.count > a.count ? b : a
    }

    /// 逗号/顿号分隔的列表合并去重
    private func mergeText(_ a: String, _ b: String) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for part in (a + "、" + b).components(separatedBy: CharacterSet(charactersIn: "、,，;；/ ")) {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || seen.contains(t) { continue }
            seen.insert(t)
            out.append(t)
        }
        return out.joined(separator: "、")
    }
}
