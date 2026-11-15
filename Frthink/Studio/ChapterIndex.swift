import Foundation

/// 小说内部目录结构（卷 → 章）。
///
/// 识别策略参考主流阅读器（legado/「阅读」的 chapterRule、Calibre 的 chapter detection、
/// 静读天下 / Apple Books 对 txt 的处理）：
///   1. 逐行扫描，而不是全文一条正则——这样才能用到"是否缩进、前后是否空行"这类版面特征；
///   2. 前缀规则覆盖卷/部/篇/集、章/节/回/话/幕、序章楔子尾声番外、Chapter/Part/Prologue；
///   3. 编号规则覆盖 `1.` `1、` `01:` `（一）` `一、` 与纯数字行，但要求顶格 + 行短；
///   4. 一律排除"太长、像句子（≥2 个句读）、以句末标点结尾"的行——这是把正文误判成章节的主因。
struct ChapterNode: Identifiable {
    var index: Int            // 全书章节序号（1-based，只数章）
    var title: String
    var start: Int
    var end: Int
    var volume: String?
    var offsetInVolume: Int

    var id: Int { index }
    var chars: Int { max(0, end - start) }
}

struct VolumeNode: Identifiable {
    var title: String
    var start: Int
    var end: Int
    var chapterRange: ClosedRange<Int>?

    var id: String { "\(start)-\(title)" }
}

enum ChapterIndex {

    private enum Kind { case chapter, volume }

    /// 最大标题长度（中文标题普遍很短；放宽到 44 是为了兼容"第X章 一长串标题"）
    private static let maxTitleChars = 44

    // MARK: - 扫描

    static func scan(_ text: String) -> (chapters: [ChapterNode], volumes: [VolumeNode]) {
        // 切行并记录每行的起始 offset（Character 口径）
        var lineStarts: [Int] = []
        var lines: [String] = []
        var offset = 0
        for raw in text.components(separatedBy: "\n") {
            lineStarts.append(offset)
            lines.append(raw)
            offset += raw.count + 1
        }

        var marks: [(offset: Int, title: String, isVolume: Bool)] = []
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.count > maxTitleChars { continue }

            let prevBlank = (i == 0) || lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty
            let nextBlank = (i == lines.count - 1) || lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty

            guard let kind = classify(line, raw: raw, prevBlank: prevBlank, nextBlank: nextBlank) else { continue }
            marks.append((lineStarts[i], line, kind == .volume))
        }

        marks.sort { $0.offset < $1.offset }

        // 去重：同一行只算一次；紧邻的两行（标题 + 副标题）只保留第一个；同名的重复章丢弃。
        // 这是"不交叉识别同一章节"的实现点。
        var deduped: [(offset: Int, title: String, isVolume: Bool)] = []
        for mark in marks {
            if let last = deduped.last {
                if last.offset == mark.offset { continue }
                if !last.isVolume && !mark.isVolume {
                    if last.title == mark.title { continue }
                    // 后一处紧贴前一处（中间没有空行）→ 视为同一章的副标题，保留第一处
                    if mark.offset - last.offset <= last.title.count + 2 { continue }
                }
            }
            deduped.append(mark)
        }
        marks = deduped

        var chapters: [ChapterNode] = []
        var volumes: [VolumeNode] = []
        var currentVolume: String?
        var volumeStart = 0
        var chapterCounter = 0
        var inVolumeCounter = 0

        for (i, mark) in marks.enumerated() {
            let nextOffset = (i + 1 < marks.count) ? marks[i + 1].offset : text.count
            if mark.isVolume {
                if let v = currentVolume {
                    volumes.append(VolumeNode(title: v, start: volumeStart,
                                              end: mark.offset,
                                              chapterRange: chapterRange(of: chapters)))
                }
                currentVolume = mark.title
                volumeStart = mark.offset
                inVolumeCounter = 0
            } else {
                chapterCounter += 1
                inVolumeCounter += 1
                chapters.append(ChapterNode(index: chapterCounter, title: mark.title,
                                            start: mark.offset, end: nextOffset,
                                            volume: currentVolume,
                                            offsetInVolume: inVolumeCounter))
            }
        }
        if let v = currentVolume {
            volumes.append(VolumeNode(title: v, start: volumeStart,
                                      end: text.count,
                                      chapterRange: chapterRange(of: chapters)))
        }

        if chapters.count > 1 {
            for i in 0..<(chapters.count - 1) {
                chapters[i].end = min(chapters[i].end, chapters[i + 1].start)
            }
        }
        if let last = chapters.last {
            chapters[chapters.count - 1].end = max(last.start, text.count)
        }

        return (chapters, volumes)
    }

    private static func chapterRange(of chapters: [ChapterNode]) -> ClosedRange<Int>? {
        guard let first = chapters.first, let last = chapters.last else { return nil }
        return first.index...last.index
    }

    // MARK: - 判定

    private static func classify(_ line: String, raw: String,
                                 prevBlank: Bool, nextBlank: Bool) -> Kind? {
        // 公共排除：句子味太重
        if let last = line.last, "。！？…”」』!?".contains(last) { return nil }
        let sentenceMarks = line.filter { "，。；！？,!?;".contains($0) }.count
        if sentenceMarks >= 2 { return nil }

        let indented = raw.hasPrefix(" ") || raw.hasPrefix("\t") || raw.hasPrefix("\u{3000}")

        // 1. 卷 / 部 / 篇 / 集
        if matches(line, #"^第[0-9０-９零一二三四五六七八九十百千万两]{1,8}[卷部篇集]"#) { return .volume }
        if matches(line, #"^[上中下]卷"#) { return .volume }
        if matches(line, #"(?i)^(volume|part)\s*[0-9ivxlc]+"#), line.count <= 30 { return .volume }
        if matches(line, #"^(正文|正文卷|卷一|卷二|卷三)\s*$"#) { return .volume }

        // 2. 章 / 节 / 回 / 话 / 幕
        if matches(line, #"^第[0-9０-９零一二三四五六七八九十百千万两]{1,8}[章节回话話幕]"#) { return .chapter }
        if matches(line, #"(?i)^(prologue|epilogue|interlude|afterword|side\s*story|chapter\s*zero)"#) { return .chapter }
        if matches(line, #"(?i)^(chapter|ch\.?)\s*[0-9０-９ivxlc]+"#) { return .chapter }
        if matches(line, #"^(序章|序言|楔子|引子|引言|前言|后记|尾声|终章|结局|大结局|番外[篇]?|外传|附录)"#) { return .chapter }
        // 单独一个「序」：要求很短，避免误伤正文
        if line == "序" || (line.hasPrefix("序") && line.count <= 6 && !line.contains("序章")) { return .chapter }
        // 包裹式：【第X章】 / [第X章] / （第X章）
        if matches(line, #"^[【\[（(]\s*第[0-9０-９零一二三四五六七八九十百千万两]{1,8}[章节回]"#) { return .chapter }
        if matches(line, #"^第[0-9０-９零一二三四五六七八九十百千万两]{1,8}[章节回]\s*[】\])）]"#) { return .chapter }

        // 3. 编号式：必须顶格（正文通常首行缩进），且行要短
        guard !indented else { return nil }
        if matches(line, #"^[0-9０-９]{1,4}\s*[、.．:：]\s*\S"#), line.count <= 30 { return .chapter }
        if matches(line, #"^[（(]\s*[0-9０-９一二三四五六七八九十]{1,4}\s*[）)]\s*\S"#), line.count <= 30 { return .chapter }
        if matches(line, #"^[一二三四五六七八九十]{1,4}\s*[、.．]\s*\S"#),
           line.count <= 30, prevBlank || nextBlank { return .chapter }
        // 纯数字独立成行（001 / 12）：必须前后有空行
        if matches(line, #"^[0-9０-９]{1,4}$"#), prevBlank || nextBlank { return .chapter }

        return nil
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression]) != nil
    }

    // MARK: - 查询

    static func chapters(in text: String) -> [ChapterNode] { scan(text).chapters }
    static func volumes(in text: String) -> [VolumeNode] { scan(text).volumes }

    static func filter(_ chapters: [ChapterNode], query: String) -> [ChapterNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    static func chapter(at anchor: Int, in chapters: [ChapterNode]) -> ChapterNode? {
        chapters.last { $0.start <= anchor }
    }
}
