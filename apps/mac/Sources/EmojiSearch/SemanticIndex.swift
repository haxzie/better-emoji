import Foundation

/// int8 emoji vectors from emoji-index.bin: Float32 scales[count] then Int8[count * dim].
final class SemanticIndex {
    let count: Int
    let dim: Int
    private let scales: [Float]
    private let vecs: [Int8]

    init(url: URL, count: Int, dim: Int) throws {
        self.count = count
        self.dim = dim
        let data = try Data(contentsOf: url)
        let scaleBytes = count * 4
        guard data.count == scaleBytes + count * dim else {
            throw NSError(domain: "EmojiSearch", code: 5, userInfo: [NSLocalizedDescriptionKey: "emoji-index.bin size doesn't match emoji-meta.json"])
        }
        scales = data.prefix(scaleBytes).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        vecs = data.suffix(from: scaleBytes).withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
    }

    func search(_ q: [Float], limit: Int) -> [(Int, Float)] {
        var hits: [(Int, Float)] = []
        hits.reserveCapacity(count)
        vecs.withUnsafeBufferPointer { v in
            for i in 0..<count {
                let off = i * dim
                var s: Float = 0
                for d in 0..<dim { s += q[d] * Float(v[off + d]) }
                hits.append((i, s * scales[i]))
            }
        }
        hits.sort { $0.1 > $1.1 }
        return Array(hits.prefix(limit))
    }
}
