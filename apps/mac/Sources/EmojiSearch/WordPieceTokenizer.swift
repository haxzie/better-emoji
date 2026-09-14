import Foundation

/// BERT uncased WordPiece tokenizer, loaded from a Hugging Face tokenizer.json.
/// Implements the subset all-MiniLM-L6-v2 needs: lowercase + strip accents,
/// punctuation/CJK splitting, greedy longest-match WordPiece, [CLS]/[SEP].
struct WordPieceTokenizer {
    private let vocab: [String: Int64]
    private let cls: Int64
    private let sep: Int64
    private let unk: Int64
    private let maxWordChars = 100
    private let maxTokens = 128

    init(url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let model = json?["model"] as? [String: Any],
              let vocabAny = model["vocab"] as? [String: Any] else {
            throw NSError(domain: "EmojiSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: "tokenizer.json has no WordPiece vocab"])
        }
        var v: [String: Int64] = [:]
        v.reserveCapacity(vocabAny.count)
        for (k, id) in vocabAny { if let n = id as? NSNumber { v[k] = n.int64Value } }
        vocab = v
        guard let cls = v["[CLS]"], let sep = v["[SEP]"], let unk = v["[UNK]"] else {
            throw NSError(domain: "EmojiSearch", code: 3, userInfo: [NSLocalizedDescriptionKey: "special tokens missing from vocab"])
        }
        self.cls = cls; self.sep = sep; self.unk = unk
    }

    func encode(_ text: String) -> [Int64] {
        var ids: [Int64] = [cls]
        for word in basicTokenize(text) {
            ids.append(contentsOf: wordPiece(word))
            if ids.count >= maxTokens - 1 { break }
        }
        ids = Array(ids.prefix(maxTokens - 1))
        ids.append(sep)
        return ids
    }

    // Lowercase, strip accents, split on whitespace, and make every punctuation
    // or CJK character its own token (BertPreTokenizer behaviour).
    private func basicTokenize(_ text: String) -> [String] {
        let lowered = text.lowercased().decomposedStringWithCanonicalMapping
        var words: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { words.append(cur); cur = "" } }
        for scalar in lowered.unicodeScalars {
            let props = scalar.properties
            if props.generalCategory == .nonspacingMark { continue }  // accent stripped
            if props.isWhitespace || scalar.value == 0 || scalar.value == 0xFFFD || props.generalCategory == .control {
                flush(); continue
            }
            if Self.isPunctuation(scalar) || Self.isCJK(scalar) {
                flush(); words.append(String(scalar)); continue
            }
            cur.unicodeScalars.append(scalar)
        }
        flush()
        return words
    }

    private func wordPiece(_ word: String) -> [Int64] {
        let chars = Array(word)
        if chars.count > maxWordChars { return [unk] }
        var out: [Int64] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: Int64? = nil
            while start < end {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if let id = vocab[sub] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unk] }
            out.append(id)
            start = end
        }
        return out
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v) || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}
