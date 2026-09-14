import AppKit
import ApplicationServices

/// Where the user is typing, so the picker can drop in next to it like the system
/// emoji picker does. Needs Accessibility access (already required for pasting).
enum FocusAnchor {
    /// Screen rect, in AppKit (bottom-left origin) coordinates, of the text caret in the
    /// frontmost app — or the focused control's frame when the app doesn't report caret
    /// bounds. `nil` when nothing useful is focused or we lack Accessibility access.
    static func current() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement

        // Preferred: bounds of the selected range (a zero-length range is the caret).
        var rangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef {
            var boundsRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(element,
                                                          kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          rangeRef, &boundsRef) == .success,
               let boundsRef, let rect = rect(from: boundsRef as! AXValue, .cgRect),
               rect.height > 0 {  // apps that don't support this return an empty rect
                return flipped(rect)
            }
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
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              size.height > 0, size.height <= 120 else { return nil }
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
