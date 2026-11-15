import Foundation

/// 正文 offset 手术的唯一入口（reports/10 §4.4）
///
/// 坐标口径：Character offset（`String.count`），与 `BookProject.anchorOffset`、`WorkRange` 一致。
/// 全应用禁止在别处直接做 String.Index 换算——一旦口径分裂，采纳重制稿后锚点必然漂移。
enum TextSurgery {

    // MARK: - 基础换算

    static func clamp(_ offset: Int, in text: String) -> Int {
        if offset < 0 { return 0 }
        let n = text.count
        return offset > n ? n : offset
    }

    static func index(_ text: String, at offset: Int) -> String.Index {
        let safe = clamp(offset, in: text)
        return text.index(text.startIndex, offsetBy: safe)
    }

    /// 越界/倒序返回 nil（调用方按"无效范围"处理，不静默改成别的区间）
    static func validRange(in text: String, start: Int, end: Int) -> Range<Int>? {
        guard start >= 0, end >= start, end <= text.count else { return nil }
        return start..<end
    }

    // MARK: - 读

    static func slice(_ text: String, start: Int, end: Int) -> String {
        guard let r = validRange(in: text, start: start, end: end) else { return "" }
        return String(text[index(text, at: r.lowerBound)..<index(text, at: r.upperBound)])
    }

    /// 范围首尾各取 edge 字（范围预览卡用：reports/07 灵感③）
    static func preview(_ text: String, start: Int, end: Int, edge: Int = 100) -> (head: String, tail: String) {
        let body = slice(text, start: start, end: end)
        let n = max(1, edge)
        let head = String(body.prefix(n))
        let tail = body.count > n ? String(body.suffix(n)) : body
        return (head, tail)
    }

    // MARK: - 写

    static func replace(_ text: String, start: Int, end: Int, with insert: String) -> String {
        guard let r = validRange(in: text, start: start, end: end) else { return text }
        let from = index(text, at: r.lowerBound)
        let to = index(text, at: r.upperBound)
        return text.replacingCharacters(in: from..<to, with: insert)
    }

    /// 区间替换造成的长度变化
    static func delta(start: Int, end: Int, insertCount: Int) -> Int {
        return insertCount - (end - start)
    }

    // MARK: - 平移（采纳重制稿后，所有 offset 都要过这一遍）

    /// - offset <= start：不动
    /// - offset >= end：整体平移 delta
    /// - 落在被替换区间内：夹到 start（语义 = "这一章开头"，比丢到章尾安全）
    static func shift(_ offset: Int, afterReplace start: Int, end: Int, delta: Int) -> Int {
        if offset <= start { return offset }
        if offset >= end { return offset + delta }
        return start
    }

    // MARK: - 段落（P3 读者意见定位用）

    /// 空行分段：返回 offset 所在段的下标（0-based）
    static func paragraphIndex(in text: String, forOffset offset: Int) -> Int? {
        guard validRange(in: text, start: 0, end: text.count) != nil else { return nil }
        let target = clamp(offset, in: text)
        var idx = 0
        var cursor = 0
        let paragraphs = text.components(separatedBy: "\n\n")
        for p in paragraphs {
            let len = p.count
            if target <= cursor + len { return idx }
            cursor += len + 2     // 补回分隔符 "\n\n"
            idx += 1
        }
        return idx
    }

    /// 段落开头 offset（找不到返回 nil）
    static func offsetOfParagraph(_ index: Int, in text: String) -> Int? {
        guard index >= 0 else { return nil }
        let paragraphs = text.components(separatedBy: "\n\n")
        guard index < paragraphs.count else { return nil }
        var cursor = 0
        for i in 0..<index {
            cursor += paragraphs[i].count + 2
        }
        return clamp(cursor, in: text)
    }

    static func paragraphText(_ index: Int, in text: String) -> String? {
        let paragraphs = text.components(separatedBy: "\n\n")
        guard index >= 0, index < paragraphs.count else { return nil }
        return paragraphs[index]
    }
}
