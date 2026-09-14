import AppKit
import ApplicationServices

/// Puts the emoji into whatever app was frontmost. With Accessibility access we
/// paste it (and restore the previous clipboard); without, it's just copied.
enum Inserter {
    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Puts the emoji into the active app.
    /// - Returns: `true` if it pasted via Cmd+V (Accessibility granted), `false` if clipboard-only.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard canPaste else { return false }
        // Give the panel a beat to close so the keystroke lands in the previous app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            postCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { restore(pb, saved) }
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
