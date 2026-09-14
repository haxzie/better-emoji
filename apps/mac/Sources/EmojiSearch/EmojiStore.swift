import Foundation

struct Emoji: Identifiable, Hashable {
    let id: Int
    let char: String
    let name: String
    let tags: [String]
    let group: Int
    let skins: [String]
}

/// Mirrors emoji-meta.json written by packages/emoji-index/scripts/build-index.mjs.
struct EmojiMeta: Decodable {
    struct Entry: Decodable {
        let c: String
        let n: String
        let t: [String]
        let g: Int
        let s: [String]?
    }
    let model: String
    let dim: Int
    let count: Int
    let groups: [String: String]
    let emoji: [Entry]
}

enum Category: Int, CaseIterable, Identifiable {
    case recent = -1
    case smileys = 0, people, animals = 3, food, travel, activities, objects, symbols, flags

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .recent: return "Frequently Used"
        case .smileys: return "Smileys & Emotion"
        case .people: return "People & Body"
        case .animals: return "Animals & Nature"
        case .food: return "Food & Drink"
        case .travel: return "Travel & Places"
        case .activities: return "Activities"
        case .objects: return "Objects"
        case .symbols: return "Symbols"
        case .flags: return "Flags"
        }
    }

    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .smileys: return "face.smiling"
        case .people: return "hand.wave"
        case .animals: return "leaf"
        case .food: return "fork.knife"
        case .travel: return "car"
        case .activities: return "soccerball"
        case .objects: return "lightbulb"
        case .symbols: return "number"
        case .flags: return "flag"
        }
    }
}

final class EmojiStore {
    let meta: EmojiMeta
    let all: [Emoji]
    let byGroup: [Category: [Emoji]]
    private let byChar: [String: Emoji]
    private let recentKey = "recent"
    private let recentLimit = 32

    init() throws {
        let data = try Data(contentsOf: Resources.url(.meta))
        meta = try JSONDecoder().decode(EmojiMeta.self, from: data)
        all = meta.emoji.enumerated().map { i, e in
            Emoji(id: i, char: e.c, name: e.n, tags: e.t, group: e.g, skins: e.s ?? [])
        }
        var groups: [Category: [Emoji]] = [:]
        for e in all {
            guard let cat = Category(rawValue: e.group) else { continue }
            groups[cat, default: []].append(e)
        }
        byGroup = groups
        byChar = Dictionary(all.map { ($0.char, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var recent: [Emoji] {
        let chars = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        return chars.compactMap { byChar[$0] }
    }

    func touchRecent(_ emoji: Emoji) {
        var chars = (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).filter { $0 != emoji.char }
        chars.insert(emoji.char, at: 0)
        UserDefaults.standard.set(Array(chars.prefix(recentLimit)), forKey: recentKey)
    }
}
