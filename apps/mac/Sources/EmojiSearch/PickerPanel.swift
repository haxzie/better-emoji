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
        animationBehavior = .none  // we animate ourselves, scaling from the caret
        contentView = view
        // Liquid Glass draws its rim along the window's backdrop, which for a borderless
        // window is a hard rectangle. Round the content layer so the backdrop matches the
        // panel shape.
        view.wantsLayer = true
        view.layer?.cornerRadius = PickerView.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
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

    /// Places the panel the way the system emoji picker does: just below the text caret
    /// of the frontmost app, left edge lined up with it, flipping above when there's no
    /// room. `anchor` overrides that (e.g. the menu bar button); with neither, the mouse.
    func show(anchor explicit: NSRect? = nil) {
        let mouse = NSEvent.mouseLocation
        let anchor = explicit ?? FocusAnchor.current() ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        let gap: CGFloat = 8
        var origin = NSPoint(x: anchor.minX - 12, y: anchor.minY - gap - frame.height)
        if origin.y < bounds.minY { origin.y = anchor.maxY + gap }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - frame.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - frame.height - 8)
        setFrameOrigin(origin)

        // Scale about the point the panel "grows" from: the caret's x on the edge that
        // faces it — top edge when we're below the caret, bottom edge when above.
        let below = origin.y + frame.height <= anchor.minY + 1
        popOrigin = CGPoint(x: min(max(anchor.midX - origin.x, 0), frame.width),
                            y: below ? frame.height : 0)

        hiding = false
        alphaValue = 0
        contentView?.layer?.transform = scaleTransform(0.8)
        makeKeyAndOrderFront(nil)
        animate(scale: 1, alpha: 1, duration: 0.24,
                timing: CAMediaTimingFunction(controlPoints: 0.2, 1.15, 0.3, 1))  // slight overshoot
        // SwiftUI's @FocusState doesn't reliably take in a borderless non-activating
        // panel, so hand the text field first-responder status directly.
        DispatchQueue.main.async { [weak self] in self?.focusSearchField() }
    }

    // MARK: - Pop animation

    private var popOrigin = CGPoint.zero
    private var hiding = false

    private func scaleTransform(_ s: CGFloat) -> CATransform3D {
        // Scale about popOrigin with the layer's default (0,0) anchor: move the point to
        // the origin, scale, move it back.
        let toOrigin = CATransform3DMakeTranslation(-popOrigin.x, -popOrigin.y, 0)
        let back     = CATransform3DMakeTranslation(popOrigin.x, popOrigin.y, 0)
        return CATransform3DConcat(CATransform3DConcat(toOrigin, CATransform3DMakeScale(s, s, 1)), back)
    }

    private func animate(scale: CGFloat, alpha: CGFloat, duration: TimeInterval,
                         timing: CAMediaTimingFunction, completion: (() -> Void)? = nil) {
        guard let layer = contentView?.layer else { completion?(); return }
        let target = scaleTransform(scale)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer.presentation()?.transform ?? layer.transform
        anim.toValue = target
        anim.duration = duration
        anim.timingFunction = timing
        layer.transform = target
        layer.add(anim, forKey: "pop")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            self.animator().alphaValue = alpha
        }, completionHandler: completion)
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
        guard !hiding else { return }
        hiding = true
        animate(scale: 0.85, alpha: 0, duration: 0.14,
                timing: CAMediaTimingFunction(name: .easeIn)) { [weak self] in
            guard let self, self.hiding else { return }
            self.orderOut(nil)
            self.contentView?.layer?.transform = CATransform3DIdentity
            self.alphaValue = 1
            self.hiding = false
            self.onHide?()
        }
    }
}
