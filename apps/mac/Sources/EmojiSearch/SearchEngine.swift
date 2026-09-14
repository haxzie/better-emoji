import Foundation
import Combine

enum SemanticState: Equatable {
    case loading
    case ready
    case failed(String)
}

/// Runs keyword search on every keystroke and merges semantic hits in after an
/// 80 ms debounce — the same policy as the web app (apps/web/src/main.ts).
@MainActor
final class SearchEngine: ObservableObject {
    @Published var query = "" { didSet { queryChanged() } }
    @Published private(set) var results: [Emoji] = []
    @Published private(set) var semantic: SemanticState = .loading
    @Published private(set) var lastQueryMs: Double?

    let store: EmojiStore
    private let keyword: KeywordIndex
    private var embedder: Embedder?
    private var index: SemanticIndex?

    private let resultLimit = 64
    private let semanticCandidates = 200
    private let debounce: Duration = .milliseconds(80)
    private let keywordWeight: Float = 0.5
    private let semanticFloor: Float = 0.3

    private var keywordHits: [(Int, Float)] = []
    private var debounceTask: Task<Void, Never>?
    private var generation = 0

    init(store: EmojiStore) {
        self.store = store
        keyword = KeywordIndex(store.all)
        loadSemantic()
    }

    private func loadSemantic() {
        let dim = store.meta.dim
        let count = store.meta.count
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let index = try SemanticIndex(url: Resources.url(.index), count: count, dim: dim)
                let embedder = try Embedder(modelURL: Resources.url(.model), tokenizerURL: Resources.url(.tokenizer), dim: dim)
                _ = try embedder.embed("hello")  // warm up the graph
                await self?.semanticLoaded(index: index, embedder: embedder)
            } catch {
                await self?.semanticFailed(error.localizedDescription)
            }
        }
    }

    private func semanticLoaded(index: SemanticIndex, embedder: Embedder) {
        self.index = index
        self.embedder = embedder
        semantic = .ready
        if !query.isEmpty { runSemantic() }
    }

    private func semanticFailed(_ message: String) {
        semantic = .failed(message)
    }

    private func queryChanged() {
        generation += 1
        debounceTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            keywordHits = []
            results = []
            return
        }
        keywordHits = keyword.search(q, limit: resultLimit)
        results = merge(keywordHits, semantic: nil)
        guard semantic == .ready else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .zero)
            guard !Task.isCancelled else { return }
            self?.runSemantic()
        }
    }

    private func runSemantic() {
        guard let embedder, let index else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let gen = generation
        let limit = semanticCandidates
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Date()
            guard let vec = try? embedder.embed(q) else { return }
            let hits = index.search(vec, limit: limit)
            let ms = Date().timeIntervalSince(t0) * 1000
            await self?.semanticDone(hits, ms: ms, generation: gen)
        }
    }

    private func semanticDone(_ hits: [(Int, Float)], ms: Double, generation gen: Int) {
        guard gen == generation else { return }  // stale
        lastQueryMs = ms
        results = merge(keywordHits, semantic: hits)
    }

    private func merge(_ kw: [(Int, Float)], semantic sem: [(Int, Float)]?) -> [Emoji] {
        var scores: [Int: (k: Float, s: Float)] = [:]
        for (i, k) in kw { scores[i] = (k, 0) }
        if let sem {
            for (i, s) in sem {
                if scores[i] != nil { scores[i]!.s = s } else if s >= semanticFloor { scores[i] = (0, s) }
            }
        }
        return scores
            .map { (id: $0.key, score: $0.value.s + keywordWeight * $0.value.k) }
            .sorted { $0.score > $1.score }
            .prefix(resultLimit)
            .map { store.all[$0.id] }
    }
}
