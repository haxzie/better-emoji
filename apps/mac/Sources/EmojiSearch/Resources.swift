import Foundation

/// Locates the index + encoder files. Inside the .app they're flattened into
/// Contents/Resources by scripts/bundle.sh; during `swift run` we fall back to
/// the workspace package at packages/emoji-index.
enum Resources {
    static let modelName = "Xenova/all-MiniLM-L6-v2"

    enum File: String {
        case meta = "emoji-meta.json"
        case index = "emoji-index.bin"
        case model = "model_quantized.onnx"
        case tokenizer = "tokenizer.json"

        /// Path relative to packages/emoji-index during development.
        var devPath: String {
            switch self {
            case .meta, .index: return "dist/\(rawValue)"
            case .model: return "models/\(modelName)/onnx/\(rawValue)"
            case .tokenizer: return "models/\(modelName)/\(rawValue)"
            }
        }
    }

    static func url(_ file: File) throws -> URL {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(file.rawValue),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let pkg = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Sources/EmojiSearch
            .appendingPathComponent("../../../../packages/emoji-index")
            .standardized
        let dev = pkg.appendingPathComponent(file.devPath)
        if fm.fileExists(atPath: dev.path) { return dev }
        throw NSError(domain: "EmojiSearch", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Missing \(file.rawValue). Run `pnpm index:fetch-model` in the workspace, or build the app with scripts/bundle.sh.",
        ])
    }
}
