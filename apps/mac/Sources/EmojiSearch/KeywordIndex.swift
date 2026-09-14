import Foundation

/// Prefix search over CLDR names + keywords. Same scoring as apps/web/src/keyword.ts:
/// catches partial words ("cele" → 🎉) and exact names that embeddings miss.
final class KeywordIndex {
    private struct Token {
        let text: String
        let emoji: Int
        let weight: Float
    }

    private static let nameWeight: Float = 1
    private static let tagWeight: Float = 0.7
    private static let prefixPenalty: Float = 0.8

    private let tokens: [Token]
    private let names: [String]

    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") })
            .map(String.init)
    }

    init(_ emoji: [Emoji]) {
        names = emoji.map { $0.name.lowercased() }
        var toks: [Token] = []
        for e in emoji {
            var seen: [String: Float] = [:]
            for w in Self.tokenize(e.name) { seen[w] = Self.nameWeight }
            for tag in e.tags { for w in Self.tokenize(tag) where seen[w] == nil { seen[w] = Self.tagWeight } }
            for (text, weight) in seen { toks.append(Token(text: text, emoji: e.id, weight: weight)) }
        }
        tokens = toks.sorted { $0.text < $1.text }
    }

    private func lowerBound(_ prefix: String) -> Int {
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tokens[mid].text < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func search(_ query: String, limit: Int) -> [(Int, Float)] {
        let words = Self.tokenize(query)
        guard !words.isEmpty else { return [] }

        var candidates: [Int: Float]? = nil
        for w in words {
            var matches: [Int: Float] = [:]
            var i = lowerBound(w)
            while i < tokens.count, tokens[i].text.hasPrefix(w) {
                let t = tokens[i]
                let s = t.weight * (t.text == w ? 1 : Self.prefixPenalty)
                if s > matches[t.emoji, default: 0] { matches[t.emoji] = s }
                i += 1
            }
            if var c = candidates {
                for (idx, prev) in c {
                    if let s = matches[idx] { c[idx] = prev + s } else { c[idx] = nil }
                }
                candidates = c
            } else {
                candidates = matches
            }
            if candidates?.isEmpty ?? true { return [] }
        }

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var hits: [(Int, Float)] = []
        for (idx, sum) in candidates! {
            var s = sum / Float(words.count)
            let name = names[idx]
            if name == q { s += 0.5 } else if name.hasPrefix(q) { s += 0.2 } else if name.contains(q) { s += 0.1 }
            s -= min(0.1, Float(name.count) / 1000)
            hits.append((idx, s))
        }
        hits.sort { $0.1 > $1.1 }
        return Array(hits.prefix(limit))
    }
}
