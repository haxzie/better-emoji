import Foundation
import Combine

enum SemanticState: Equatable {
    case loading
    case ready
    case failed(String)
}

/// Debounces keystrokes (100 ms), then runs keyword + semantic search together so the
/// grid re-renders once per pause instead of once per key. Scoring mirrors the web app
/// (apps/web/src/main.ts).
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
    private let debounce: Duration = .milliseconds(100)
    private let keywordWeight: Float = 0.5     // final = semantic + keywordWeight * keyword
    private let semanticFloor: Float = 0.35    // absolute floor — matches web SEMANTIC_FLOOR
    private let semanticRelative: Float = 0.55 // drop hits < this fraction of best — matches web SEMANTIC_RELATIVE
    private let semanticMinKeep = 12           // always keep top-N semantic — matches web SEMANTIC_MIN_KEEP

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
        if !query.isEmpty { runSearch() }
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
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .zero)
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    /// Keyword search is synchronous and cheap; semantic runs off-main and the two are
    /// published together in `searchDone` so the grid updates once.
    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        keywordHits = keyword.search(q, limit: resultLimit)
        guard let embedder, let index else {
            results = merge(keywordHits, semantic: nil)  // model still loading: keyword only
            return
        }
        let gen = generation
        let limit = semanticCandidates
        Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = Date()
            guard let vec = try? embedder.embed(q) else { return }
            let hits = index.search(vec, limit: limit)
            let ms = Date().timeIntervalSince(t0) * 1000
            await self?.searchDone(hits, ms: ms, generation: gen)
        }
    }

    private func searchDone(_ hits: [(Int, Float)], ms: Double, generation gen: Int) {
        guard gen == generation else { return }  // stale
        lastQueryMs = ms
        results = merge(keywordHits, semantic: hits)
    }

    /// Mirrors apps/web/src/main.ts `merge()` exactly:
    ///   cutoff = max(semanticFloor, bestSemanticScore × semanticRelative)
    ///   keep a semantic-only hit if rank < semanticMinKeep OR score ≥ cutoff
    ///   final score = s + keywordWeight × k
    private func merge(_ kw: [(Int, Float)], semantic sem: [(Int, Float)]?) -> [Emoji] {
        var scores: [Int: (k: Float, s: Float)] = [:]
        for (i, k) in kw { scores[i] = (k, 0) }
        if let sem, !sem.isEmpty {
            let best = sem[0].1
            let cutoff = max(semanticFloor, best * semanticRelative)
            for (rank, (i, s)) in sem.enumerated() {
                if var entry = scores[i] {
                    entry.s = s
                    scores[i] = entry
                } else if rank < semanticMinKeep || s >= cutoff {
                    scores[i] = (0, s)
                }
            }
        }
        return scores
            .map { (id: $0.key, score: $0.value.s + keywordWeight * $0.value.k) }
            .sorted { $0.score > $1.score }
            .prefix(resultLimit)
            .map { store.all[$0.id] }
    }
}
