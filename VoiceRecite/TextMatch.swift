import Foundation

/// 文本归一化：只保留「字」（汉字 / 字母 / 数字），去掉标点、空格、换行；英文小写。
enum TextMatch {

    static func normalize(_ text: String) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(text.count)
        for ch in text {
            if ch.isLetter || ch.isNumber {
                for c in ch.lowercased() {
                    out.append(c)
                }
            }
        }
        return out
    }

    /// 是不是「字」（用来做逐字高亮，标点不高亮）
    static func isWord(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }
}
