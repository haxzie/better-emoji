import AppKit

/// Floating, non-activating panel: the app that had focus keeps it, so a pick
/// can paste straight into it — the same trick the system emoji picker uses.
final class PickerPanel: NSPanel {
    var onHide: (() -> Void)?

    init(contentView view: NSView) {
        super.init(
            contentRect: view.frame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        contentView = view
        // Always light — matches the web app aesthetic.
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Emacs-style ctrl+letter bindings (ctrl+a = beginning, ctrl+e = end, ctrl+k = kill, …)
    /// don't reach the field editor in a non-activating panel because AppKit's text system
    /// skips `interpretKeyEvents` when the hosting app isn't "active". Re-deliver them
    /// directly onto the first responder so the standard key-binding machinery handles them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           let fr = firstResponder, fr !== self {
            fr.tryToPerform(#selector(NSResponder.keyDown(with:)), with: event)
            return
        }
        super.sendEvent(event)
    }

    /// Clicking anywhere else dismisses the picker.
    override func resignKey() {
        super.resignKey()
        if isVisible { hide() }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height - 16)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - frame.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - frame.height - 8)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        // SwiftUI's @FocusState doesn't reliably take in a borderless non-activating
        // panel, so hand the text field first-responder status directly.
        DispatchQueue.main.async { [weak self] in self?.focusSearchField() }
    }

    private func focusSearchField() {
        func find(_ v: NSView) -> NSTextField? {
            if let t = v as? NSTextField, t.isEditable { return t }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        if let field = contentView.flatMap(find) { makeFirstResponder(field) }
    }

    func hide() {
        orderOut(nil)
        onHide?()
    }
}
