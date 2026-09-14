import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.haxzie.better-emoji", category: "anchor")

/// Where the user is typing, so the picker can drop in next to it like the system
/// emoji picker does. Needs Accessibility access (already required for pasting).
enum FocusAnchor {
    /// Screen rect, in AppKit (bottom-left origin) coordinates, of the text caret in the
    /// frontmost app — or the focused control's frame when the app doesn't report caret
    /// bounds. `nil` when nothing useful is focused or we lack Accessibility access.
    static func current() -> NSRect? {
        guard AXIsProcessTrusted() else { log.info("not trusted"); return nil }
        var focusedRef: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                     kAXFocusedUIElementAttribute as CFString,
                                                     &focusedRef)
        guard focusErr == .success, let focusedRef else { log.info("no focused element: \(focusErr.rawValue)"); return nil }
        let element = focusedRef as! AXUIElement
        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? "?"
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        log.info("focused \(role, privacy: .public) in \(appName, privacy: .public)")

        // Preferred: bounds of the selected range (a zero-length range is the caret).
        var rangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            var range = CFRange(); AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
            var boundsRef: AnyObject?
            let err = AXUIElementCopyParameterizedAttributeValue(element,
                                                                 kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                 rangeRef, &boundsRef)
            let bounds = boundsRef.flatMap { Self.rect(from: $0 as! AXValue, .cgRect) }
            let desc = bounds.map { "\($0)" } ?? "nil"
            log.info("range \(range.location),\(range.length) → bounds err=\(err.rawValue) rect=\(desc, privacy: .public)")
            if err == .success, let bounds, bounds.height > 0 {  // apps that don't support this return an empty rect
                return flipped(bounds)
            }
        } else {
            log.info("no selected text range")
        }

        // Fallback: the focused control's frame — useful for single-line fields whose
        // toolkit doesn't implement AXBoundsForRange. Skip big containers (web areas,
        // text views spanning the window); anchoring under those is worse than the mouse.
        var posRef: AnyObject?, sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        log.info("element frame \(origin.x),\(origin.y) \(size.width)x\(size.height)")
        guard size.height > 0, size.height <= 120 else { return nil }
        return flipped(CGRect(origin: origin, size: size))
    }

    private static func rect(from value: AXValue, _ type: AXValueType) -> CGRect? {
        var r = CGRect.zero
        return AXValueGetValue(value, type, &r) ? r : nil
    }

    /// AX reports Quartz coordinates (top-left origin on the primary display).
    private static func flipped(_ r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }
}
