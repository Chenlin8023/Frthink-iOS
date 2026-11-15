import Foundation

/// 分析作用范围（P1 起取代 WorkRange）。
///
/// 语义只有一个：**锚之前的正文**。用「最近 N 章」控制体量，不再让用户理解任意字符区间。
/// 续写不看这个设置——续写永远从锚之后开始，锚前尾部字数由 SettingsStore.contextBudget 控制。
enum AnalysisScope {

    static let defaultChapters = 30
    static let chapterOptions = [10, 20, 30, 50, 0]   // 0 = 全部锚前
    /// 识别不到章节时的兜底：每"章"按 4000 字估算
    static let charsPerChapter = 4000

    private static func key(_ id: UUID) -> String { "scope.chapters.\(id.uuidString)" }

    // MARK: 设置

    static func chapterLimit(for project: BookProject) -> Int {
        guard let raw = UserDefaults.standard.object(forKey: key(project.id)) as? Int else {
            return defaultChapters
        }
        return max(0, raw)
    }

    static func setChapterLimit(_ n: Int, for project: BookProject) {
        UserDefaults.standard.set(max(0, n), forKey: key(project.id))
    }

    static func limitLabel(_ limit: Int) -> String {
        limit == 0 ? "全部锚前" : "最近 \(limit) 章"
    }

    // MARK: 坐标

    /// 生效锚：未设锚时等于正文末尾（语义 = "写到哪算哪"）
    static func anchor(of project: BookProject) -> Int {
        let n = project.body.count
        guard let a = project.anchorOffset else { return n }
        return min(max(a, 0), n)
    }

    static func anchorIsExplicit(_ project: BookProject) -> Bool {
        project.anchorOffset != nil
    }

    /// 锚前的章节切片（标题 + 起止 offset），按正文顺序
    static func chaptersBeforeAnchor(_ project: BookProject) -> [(title: String, start: Int, end: Int)] {
        let end = anchor(of: project)
        guard end > 0 else { return [] }
        let ranges = PromptBuilder.chapterRanges(in: project.body)
        guard !ranges.isEmpty else { return [] }
        var out: [(title: String, start: Int, end: Int)] = []
        for (i, r) in ranges.enumerated() where r.offset < end {
            let next = (i + 1 < ranges.count) ? ranges[i + 1].offset : project.body.count
            let stop = min(next, end)
            if stop > r.offset {
                out.append((title: r.title, start: r.offset, end: stop))
            }
        }
        return out
    }

    static func chapterCount(beforeAnchorOf project: BookProject) -> Int {
        chaptersBeforeAnchor(project).count
    }

    /// 作用区间：最近 limit 章（limit == 0 表示全部锚前；无章节时按字数估算）
    static func range(for project: BookProject) -> (start: Int, end: Int) {
        let end = anchor(of: project)
        guard end > 0 else { return (0, 0) }
        let limit = chapterLimit(for: project)
        let chapters = chaptersBeforeAnchor(project)

        if chapters.isEmpty {
            if limit == 0 { return (0, end) }
            let span = limit * charsPerChapter
            return (max(0, end - span), end)
        }
        if limit == 0 || limit >= chapters.count {
            return (chapters[0].start, end)
        }
        let start = chapters[chapters.count - limit].start
        return (start, end)
    }

    // MARK: 取文本

    /// 分析用正文（锚前 · 最近 N 章）
    static func text(for project: BookProject) -> String {
        let r = range(for: project)
        guard r.end > r.start else { return "" }
        return TextSurgery.slice(project.body, start: r.start, end: r.end)
    }

    /// 需要"尾部 N 字"语义的地方（规则归纳等）复用同一区间；区间为空时退化为锚前尾部
    static func tailText(for project: BookProject, fallbackChars: Int) -> String {
        let body = text(for: project)
        if !body.isEmpty { return body }
        let end = anchor(of: project)
        let start = max(0, end - max(1, fallbackChars))
        return TextSurgery.slice(project.body, start: start, end: end)
    }

    // MARK: 展示

    /// 例："锚前最近 30 章（第 12–41 章 · 约 96000 字）" / "锚前（未识别章节 · 约 4200 字）"
    static func label(for project: BookProject) -> String {
        let limit = chapterLimit(for: project)
        let r = range(for: project)
        let chars = max(0, r.end - r.start)
        let chapters = chaptersBeforeAnchor(project)
        let head = limit == 0 ? "锚前全部" : "锚前\(limitLabel(limit))"

        if chapters.isEmpty {
            return "\(head)（未识别章节 · 约 \(chars) 字）"
        }
        // 反推区间覆盖到哪几章
        let covered = chapters.filter { $0.end > r.start }
        guard let first = covered.first, let last = covered.last else {
            return "\(head)（约 \(chars) 字）"
        }
        let a = chapters.firstIndex { $0.start == first.start }.map { $0 + 1 } ?? 0
        let b = chapters.firstIndex { $0.start == last.start }.map { $0 + 1 } ?? 0
        return "\(head)（第 \(a)–\(b) 章 · 约 \(chars) 字）"
    }

    /// 锚前的首尾预览（设锚时确认"选的就是这里"）
    static func anchorPreview(_ project: BookProject, edge: Int = 100) -> (head: String, tail: String) {
        let end = anchor(of: project)
        let start = max(0, end - max(edge * 2, 200))
        let body = TextSurgery.slice(project.body, start: start, end: end)
        let head = String(body.prefix(edge))
        let tail = body.count > edge ? String(body.suffix(edge)) : body
        return (head, tail)
    }
}
