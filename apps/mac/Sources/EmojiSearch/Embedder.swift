import Foundation
import OnnxRuntimeBindings

/// all-MiniLM-L6-v2 (int8) via ONNX Runtime: tokenize → transformer → mean pool → L2 normalize.
/// Same model file the web app serves, so rankings match.
final class Embedder {
    let dim: Int
    private let tokenizer: WordPieceTokenizer
    private let env: ORTEnv
    private let session: ORTSession
    private var cache: [String: [Float]] = [:]
    private let cacheLimit = 500

    init(modelURL: URL, tokenizerURL: URL, dim: Int) throws {
        self.dim = dim
        tokenizer = try WordPieceTokenizer(url: tokenizerURL)
        env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setIntraOpNumThreads(2)
        try opts.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)
    }

    func embed(_ text: String) throws -> [Float] {
        if let hit = cache[text] { return hit }
        let ids = tokenizer.encode(text)
        let n = ids.count
        let shape: [NSNumber] = [1, NSNumber(value: n)]
        func tensor(_ v: [Int64]) throws -> ORTValue {
            try ORTValue(tensorData: NSMutableData(bytes: v, length: v.count * 8), elementType: .int64, shape: shape)
        }
        let inputs = [
            "input_ids": try tensor(ids),
            "attention_mask": try tensor([Int64](repeating: 1, count: n)),
            "token_type_ids": try tensor([Int64](repeating: 0, count: n)),
        ]
        let out = try session.run(withInputs: inputs, outputNames: ["last_hidden_state"], runOptions: nil)
        guard let hidden = out["last_hidden_state"] else { throw NSError(domain: "EmojiSearch", code: 4) }
        let data = try hidden.tensorData() as Data
        let vec = data.withUnsafeBytes { raw -> [Float] in
            let f = raw.bindMemory(to: Float.self)
            var acc = [Float](repeating: 0, count: dim)
            for t in 0..<n {
                let off = t * dim
                for d in 0..<dim { acc[d] += f[off + d] }
            }
            var norm: Float = 0
            for d in 0..<dim { acc[d] /= Float(n); norm += acc[d] * acc[d] }
            norm = norm.squareRoot()
            if norm > 0 { for d in 0..<dim { acc[d] /= norm } }
            return acc
        }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[text] = vec
        return vec
    }
}
