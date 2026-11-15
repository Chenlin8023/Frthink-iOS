import Foundation

/// 小说内部目录结构（卷 → 章）。
///
/// 存在理由：v1.9 只有一条章节正则，且 `[章节回卷部篇]` 把「第一卷」也当成章，
/// 于是锚前章数虚高、锚 sheet 里几百条平铺、无法按卷定位。
/// 这里把「卷」和「章」分成两套模式，产出可直接跳转的树。
struct ChapterNode: Identifiable {
    var index: Int            // 全书章节序号（1-based，只数章）
    var title: String
    var start: Int
    var end: Int
    var volume: String?       // 所属卷标题（nil = 卷外）
    var offsetInVolume: Int   // 卷内序号（1-based）

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

    /// 只认章（含序章/楔子/尾声/后记/番外），不认卷
    static let chapterPattern = "^\\s*(第[0-9０-９零一二三四五六七八九十百千万两]{1,8}[章节回]|序章|楔子|引子|尾声|后记|番外[篇]?|Chapter\\s*[0-9０-９]+|CHAPTER\\s+[0-9]+).*$"

    /// 只认卷/部/篇
    static let volumePattern = "^\\s*(第[0-9０-９零一二三四五六七八九十百千万两]{1,8}[卷部篇]|[上中下]卷|Volume\\s*[0-9]+|Part\\s*[0-9]+).*$"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern,
                                  options: [.anchorsMatchLines, .caseInsensitive]))
            ?? (try! NSRegularExpression(pattern: "^$", options: [.anchorsMatchLines]))
    }

    /// 像不像一个标题行：太长的、句子式（标点多）的、空白的都不算。
    /// 这一层过滤是"划分不准"的主要修法——正则只能认出前缀，长度与标点才分得清正文。
    static func isPlausibleTitle(_ raw: String, limit: Int) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t.count > limit { return false }
        let sentenceMarks = t.filter { "，。；！？,!?;".contains($0) }.count
        if sentenceMarks >= 2 { return false }
        // 纯数字/纯符号不算标题
        let meaningful = t.filter { $0.isLetter || $0.isNumber || $0 == "章" || $0 == "节" }
        if meaningful.count < 2 { return false }
        return true
    }

    /// 全文扫描：一次拿到章 + 卷，按出现顺序建树
    static func scan(_ text: String) -> (chapters: [ChapterNode], volumes: [VolumeNode]) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var marks: [(offset: Int, title: String, isVolume: Bool)] = []
        for m in regex(chapterPattern).matches(in: text, range: full) {
            let t = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            if isPlausibleTitle(t, limit: 44) { marks.append((m.range.location, t, false)) }
        }
        for m in regex(volumePattern).matches(in: text, range: full) {
            let t = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            if isPlausibleTitle(t, limit: 30) { marks.append((m.range.location, t, true)) }
        }
        marks.sort { $0.offset < $1.offset }

        var chapters: [ChapterNode] = []
        var volumes: [VolumeNode] = []
        var currentVolume: String?
        var volumeStart: Int = 0
        var chapterCounter = 0
        var inVolumeCounter = 0

        for (i, mark) in marks.enumerated() {
            let nextOffset = (i + 1 < marks.count) ? marks[i + 1].offset : ns.length
            if mark.isVolume {
                // 收尾上一个卷
                if currentVolume != nil {
                    volumes.append(VolumeNode(title: currentVolume!, start: volumeStart,
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
        if currentVolume != nil {
            volumes.append(VolumeNode(title: currentVolume!, start: volumeStart,
                                      end: ns.length,
                                      chapterRange: chapterRange(of: chapters)))
        }
        // 修正每章 end：下一章的开头（跨卷时也成立，因为 marks 已按 offset 排序）
        if chapters.count > 1 {
            for i in 0..<(chapters.count - 1) {
                chapters[i].end = min(chapters[i].end, chapters[i + 1].start)
            }
        }
        if let last = chapters.last {
            chapters[chapters.count - 1].end = max(last.start, ns.length)
        }
        return (chapters, volumes)
    }

    private static func chapterRange(of chapters: [ChapterNode]) -> ClosedRange<Int>? {
        guard let first = chapters.first, let last = chapters.last else { return nil }
        return first.index...last.index
    }

    static func chapters(in text: String) -> [ChapterNode] {
        scan(text).chapters
    }

    static func volumes(in text: String) -> [VolumeNode] {
        scan(text).volumes
    }

    /// 按标题/关键词过滤（空词 = 全部）
    static func filter(_ chapters: [ChapterNode], query: String) -> [ChapterNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    /// 锚所在章（最后一个 start <= anchor 的章；锚在最前面时为 nil）
    static func chapter(at anchor: Int, in chapters: [ChapterNode]) -> ChapterNode? {
        chapters.last { $0.start <= anchor }
    }
}
