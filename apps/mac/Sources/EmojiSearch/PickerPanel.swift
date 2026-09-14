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
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘A/⌘C/⌘V/… — a non-activating panel isn't guaranteed to get the main menu's
        // key-equivalent pass, so run it explicitly.
        if event.type == .keyDown, mods.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        if event.type == .keyDown, mods == .control,
           let fr = firstResponder, fr !== self {
            // ⌃A selects all, like ⌘A. (AppKit's default is the Emacs "go to start of
            // line", which nobody expects in a one-line search box.)
            if event.charactersIgnoringModifiers == "a" {
                fr.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                return
            }
            // Other ⌃-letter bindings (⌃E end, ⌃K kill, …) don't reach the field editor
            // in a non-activating panel; hand them straight to the first responder.
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
