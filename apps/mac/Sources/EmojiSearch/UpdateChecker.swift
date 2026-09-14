import AppKit
import Foundation

// MARK: - GitHub types

private struct GHRelease: Decodable {
    let tagName: String
    let htmlUrl: String
    let body: String?
    let assets: [GHAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"; case htmlUrl = "html_url"; case body; case assets
    }
}

private struct GHAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let size: Int
    enum CodingKeys: String, CodingKey {
        case name; case browserDownloadUrl = "browser_download_url"; case size
    }
}

// MARK: - Checker

@MainActor
final class UpdateChecker: NSObject, ObservableObject {

    enum State {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String?, htmlUrl: String, zipUrl: String?)
        case downloading(progress: Double, total: Int64)
        case installing
        case failed(String)
    }

    @Published var state: State = .idle

    private let currentVersion: String
    private let apiURL = URL(string: "https://api.github.com/repos/haxzie/better-emoji/releases/latest")!
    private var session: URLSession?
    private var downloadContinuation: CheckedContinuation<URL, Error>?

    override init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        super.init()
    }

    // MARK: - Public

    func check() {
        state = .checking
        Task {
            do {
                var req = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: req)
                let release   = try JSONDecoder().decode(GHRelease.self, from: data)
                let latest    = versionString(from: release.tagName)
                if newerThan(current: currentVersion, candidate: latest) {
                    let zip = release.assets.first(where: { isMacZip($0.name) })?.browserDownloadUrl
                    state = .available(version: latest, notes: firstLines(release.body, 3),
                                      htmlUrl: release.htmlUrl, zipUrl: zip)
                } else {
                    state = .upToDate
                    try? await Task.sleep(for: .seconds(4))
                    if case .upToDate = state { state = .idle }
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Download and install the update in-place, then relaunch.
    func install(zipUrl: String, htmlUrl: String) {
        // If we can't write to the app's parent directory, open the releases page.
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.open(URL(string: htmlUrl)!)
            return
        }

        state = .downloading(progress: 0, total: 0)
        Task {
            do {
                let zipURL = try await download(from: URL(string: zipUrl)!)
                state = .installing
                try await unzipAndReplace(zipURL: zipURL)
                // The replacement shell script outlives us; quit so it can run.
                NSApp.terminate(nil)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func retry() { state = .idle }

    // MARK: - Download with progress

    private func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            downloadContinuation = cont
            let cfg = URLSessionConfiguration.default
            let s   = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            s.downloadTask(with: url).resume()
        }
    }

    // MARK: - Install

    private func unzipAndReplace(zipURL: URL) async throws {
        let fm      = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("emoji-update-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // unzip
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments     = ["-q", zipURL.path, "-d", tempDir.path]
        try unzip.run()
        await waitForExit(unzip)
        guard unzip.terminationStatus == 0 else {
            throw Err("unzip failed (status \(unzip.terminationStatus))")
        }

        // find the .app
        let entries = try fm.contentsOfDirectory(atPath: tempDir.path)
        guard let appEntry = entries.first(where: { $0.hasSuffix(".app") }) else {
            throw Err("No .app bundle found in the archive")
        }
        let newApp     = tempDir.appendingPathComponent(appEntry)
        let currentApp = Bundle.main.bundleURL

        // Write a replacement script that runs after we exit.
        let scriptPath = fm.temporaryDirectory.appendingPathComponent("emoji-update.sh").path
        let script = """
        #!/bin/bash
        sleep 1.5
        rm -rf \(sq(currentApp.path))
        /usr/bin/ditto \(sq(newApp.path)) \(sq(currentApp.path))
        /usr/bin/open \(sq(currentApp.path))
        rm -f "$0"
        """
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                             ofItemAtPath: scriptPath)

        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments     = [scriptPath]
        try bash.run()   // intentionally detached — keep running after we quit
    }

    // MARK: - Helpers

    private func waitForExit(_ p: Process) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { p.waitUntilExit(); cont.resume() }
        }
    }

    private func versionString(from tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private func newerThan(current: String, candidate: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func isMacZip(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip") && (lower.contains("mac") || lower.contains("macos") || lower.contains("osx"))
    }

    /// Shell-quote a path.
    private func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''}"#) + "'" }

    private func firstLines(_ text: String?, _ n: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.components(separatedBy: "\n").prefix(n).joined(separator: "\n")
    }

    private struct Err: LocalizedError {
        let errorDescription: String?
        init(_ msg: String) { errorDescription = msg }
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateChecker: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData _: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite total: Int64) {
        let progress = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
        Task { @MainActor in self.state = .downloading(progress: progress, total: total) }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // Move the file before the session cleans it up.
        let dest = FileManager.default.temporaryDirectory
                     .appendingPathComponent(UUID().uuidString + ".zip")
        try? FileManager.default.moveItem(at: location, to: dest)
        Task { @MainActor in
            self.downloadContinuation?.resume(returning: dest)
            self.downloadContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.downloadContinuation?.resume(throwing: error)
            self.downloadContinuation = nil
        }
    }
}
