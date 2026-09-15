import AppKit
import os
import ApplicationServices

/// Puts the emoji into whatever app was frontmost. With Accessibility access we
/// paste it (and restore the previous clipboard); without, it's just copied.
private let log = Logger(subsystem: "com.haxzie.better-emoji", category: "pick")

enum Inserter {
    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Puts the emoji into the active app.
    /// - Returns: `true` if it pasted via Cmd+V (Accessibility granted), `false` if clipboard-only.
    /// Restore scheduled by the last insert, and what the user had on the clipboard
    /// before we took it. Consecutive picks used to race: pick #2 snapshotted pick #1's
    /// emoji as the "original", then pick #1's restore fired and swapped the clipboard
    /// back before ⌘V #2 was processed — so nothing (or the wrong thing) got pasted.
    private static var pendingRestore: DispatchWorkItem?
    private static var original: [[NSPasteboard.PasteboardType: Data]]?

    @discardableResult
    static func insert(_ text: String, into target: NSRunningApplication? = nil) -> Bool {
        let pb = NSPasteboard.general
        // If a restore is still pending, we own the clipboard: keep the user's real
        // original rather than snapshotting our previous emoji.
        pendingRestore?.cancel()
        let saved = original ?? snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        log.info("insert \(text, privacy: .public): trusted=\(canPaste) target=\(target?.localizedName ?? "?", privacy: .public) weAreActive=\(NSApp.isActive)")
        guard canPaste else { original = nil; return false }  // copy-only: leave it on the clipboard
        original = saved

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // ⌘V goes to the *active* app. If that's us (it is, after the Settings window
            // has been open), hand activation back to the app the picker was opened over.
            var delay: TimeInterval = 0
            if NSApp.isActive, let target, !target.isActive {
                log.info("we're active — activating \(target.localizedName ?? "?", privacy: .public) first")
                target.activate()
                delay = 0.12
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                log.info("posting ⌘V; front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)")
                postCommandV()
                // Long enough for slow (Electron) apps to service the paste; cancelled and
                // superseded if another pick comes first.
                let work = DispatchWorkItem {
                    restore(pb, saved)
                    original = nil
                    pendingRestore = nil
                }
                pendingRestore = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            }
        }
        return true
    }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { d[type] = data } }
            return d
        }
    }

    private static func restore(_ pb: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        guard !items.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }
}
