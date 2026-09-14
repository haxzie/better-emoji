import AppKit
import Carbon
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // `EmojiSearch --probe "ship it" "feeling great"` prints top hits and exits;
        // handy for checking the Swift pipeline against packages/emoji-index/scripts/probe.mjs.
        let args = CommandLine.arguments
        if args.count > 2, args[1] == "--probe" {
            probe(Array(args.dropFirst(2)))
            return
        }
        // `--anchor out.txt`: report Accessibility status and the caret rect we'd anchor
        // to (whatever is focused when this runs), then quit. Launch via `open` so TCC
        // attributes the request to the app, not the shell.
        if let i = args.firstIndex(of: "--anchor"), args.count > i + 1 {
            let trusted = AXIsProcessTrusted()
            let anchor = FocusAnchor.current().map { "\($0)" } ?? "nil"
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            try? "trusted=\(trusted) frontmost=\(front) anchor=\(anchor)\n".write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem?
    private var panel: PickerPanel!
    private var hotKey: HotKey?
    private var engine: SearchEngine!
    private let panelState = PanelState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            engine = SearchEngine(store: try EmojiStore())
        } catch {
            let alert = NSAlert()
            alert.messageText = "Better Emoji can't start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let root = PickerView()
            .environmentObject(engine)
            .environmentObject(panelState)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: PickerView.width, height: PickerView.height)
        panel = PickerPanel(contentView: hosting)
        setUpMainMenu()
        panel.onHide = { [weak self] in self?.engine.query = "" }

        panelState.onPick = { [weak self] _, char in
            self?.panel.hide()
            let pasted = Inserter.insert(char)
            if !pasted { self?.showCopiedFeedback(char) }
        }
        panelState.onDismiss = { [weak self] in self?.panel.hide() }

        if UserDefaults.standard.object(forKey: "showMenuBarIcon") == nil {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        }
        if UserDefaults.standard.bool(forKey: "showMenuBarIcon") { setUpStatusItem() }

        registerHotKey()

        // Re-register the hotkey and toggle the status bar icon when settings change.
        NotificationCenter.default.addObserver(self, selector: #selector(applyShortcutChange),
                                               name: .shortcutChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyMenuBarChange),
                                               name: .menuBarVisibilityChanged, object: nil)

        // On first launch (or whenever Accessibility isn't granted yet), prompt the user so
        // emoji insertion works like the system picker — no separate "Enable" step required.
        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Inserter.requestAccessibility()
            }
        }

        let args = CommandLine.arguments
        let isCLI = args.contains("--show") || args.contains("--snapshot")
        if !isCLI {
            // Launched from Finder / dock: show the settings window.
            SettingsWindowController.shared.show()
        }
        if args.contains("--show") { toggle() }
        // `--snapshot out.png [query]`: show, wait for the model, optionally search,
        // render the panel to a PNG and quit. Lets us eyeball the UI headlessly.
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
            let path = args[i + 1]
            let query = args.count > i + 2 ? args[i + 2] : ""
            toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                // Type it through the responder chain so focus handling is exercised too.
                // "^x" sends ⌃x and "%x" sends ⌘x, e.g. "fire^ax" = type fire, ⌃A, type x.
                var pendingModifier: NSEvent.ModifierFlags = []
                for ch in query {
                    switch ch {
                    case "^": pendingModifier = .control
                    case "%": pendingModifier = .command
                    default:
                        typeKey(String(ch), modifiers: pendingModifier)
                        pendingModifier = []
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    snapshot(to: path)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func typeKey(_ chars: String, modifiers: NSEvent.ModifierFlags = []) {
        // Real ⌃/⌘ key events carry the control character in `characters`.
        let characters = modifiers.contains(.control)
            ? String(chars.unicodeScalars.compactMap { Unicode.Scalar($0.value & 0x1F) }.map(Character.init))
            : chars
        for down in [true, false] {
            guard let ev = NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0
            ) else { continue }
            panel.sendEvent(ev)
        }
    }

    private func snapshot(to path: String) {
        // Ask the window server for the composited window (glass, blur and all) — allowed
        // without Screen Recording permission because the window is ours. Pad the capture
        // so anything drawn outside the window bounds (shadow, stray borders) is visible.
        let pad: CGFloat = 12
        let f = panel.frame
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let quartz = CGRect(x: f.minX - pad, y: primaryH - f.maxY - pad, width: f.width + 2 * pad, height: f.height + 2 * pad)
        guard let cg = CGWindowListCreateImage(quartz, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func probe(_ queries: [String]) {
        do {
            let store = try EmojiStore()
            let index = try SemanticIndex(url: Resources.url(.index), count: store.meta.count, dim: store.meta.dim)
            let embedder = try Embedder(modelURL: Resources.url(.model), tokenizerURL: Resources.url(.tokenizer), dim: store.meta.dim)
            _ = try embedder.embed("hello")
            for q in queries {
                let t0 = Date()
                let hits = index.search(try embedder.embed(q), limit: 10)
                let ms = Date().timeIntervalSince(t0) * 1000
                let line = hits.map { "\(store.all[$0.0].char) \(String(format: "%.2f", $0.1))" }.joined(separator: "  ")
                print(q.padding(toLength: 26, withPad: " ", startingAt: 0), String(format: "%5.1fms", ms), line)
            }
        } catch {
            FileHandle.standardError.write("probe failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // Re-open settings when the user double-clicks the app icon while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    // MARK: - Hotkey

    private func registerHotKey() {
        hotKey = nil  // unregisters the old one via deinit
        let ud = UserDefaults.standard
        let kc  = ud.object(forKey: "shortcutKeyCode") == nil ? kVK_Space : ud.integer(forKey: "shortcutKeyCode")
        let useCtrl  = ud.object(forKey: "shortcutCtrl")  == nil ? true  : ud.bool(forKey: "shortcutCtrl")
        let useOpt   = ud.object(forKey: "shortcutOpt")   == nil ? true  : ud.bool(forKey: "shortcutOpt")
        let useShift = ud.bool(forKey: "shortcutShift")
        let useCmd   = ud.bool(forKey: "shortcutCmd")
        var mods: UInt32 = 0
        if useCtrl  { mods |= UInt32(controlKey) }
        if useOpt   { mods |= UInt32(optionKey)  }
        if useShift { mods |= UInt32(shiftKey)   }
        if useCmd   { mods |= UInt32(cmdKey)     }
        hotKey = HotKey(keyCode: UInt32(kc), modifiers: mods) { [weak self] in self?.toggle() }
        // Update the status bar tooltip to reflect the new shortcut.
        statusItem?.button?.toolTip = "Better Emoji  \(shortcutDisplayString())"
    }

    @objc private func applyShortcutChange() { registerHotKey() }

    private func shortcutDisplayString() -> String {
        let ud = UserDefaults.standard
        var s = ""
        if ud.object(forKey: "shortcutCtrl") == nil ? true  : ud.bool(forKey: "shortcutCtrl")  { s += "⌃" }
        if ud.object(forKey: "shortcutOpt")  == nil ? true  : ud.bool(forKey: "shortcutOpt")   { s += "⌥" }
        if ud.bool(forKey: "shortcutShift") { s += "⇧" }
        if ud.bool(forKey: "shortcutCmd")   { s += "⌘" }
        let kc = ud.object(forKey: "shortcutKeyCode") == nil ? kVK_Space : ud.integer(forKey: "shortcutKeyCode")
        s += kc == kVK_Space ? "Space" : "Key"
        return s
    }

    // MARK: - Main menu

    /// A menu-bar-less (LSUIElement) app has no Edit menu, so ⌘A/⌘C/⌘V/⌘X/⌘Z have no key
    /// equivalents and silently do nothing in text fields. The menu is never shown; it
    /// exists purely so AppKit routes those shortcuts to the first responder.
    private func setUpMainMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let app = NSMenu(title: "Better Emoji")
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Better Emoji", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let main = NSMenu()
        for (title, submenu) in [("Better Emoji", app), ("Edit", edit)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    // MARK: - Status item

    @objc private func applyMenuBarChange() {
        let show = UserDefaults.standard.bool(forKey: "showMenuBarIcon")
        if show && statusItem == nil {
            setUpStatusItem()
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Better Emoji")
        button.toolTip = "Better Emoji  \(shortcutDisplayString())"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Briefly changes the menu-bar icon to show the emoji was copied to the clipboard.
    private func showCopiedFeedback(_ char: String) {
        guard let button = statusItem?.button else { return }
        // Show the emoji itself in the status bar for 1.5 s so the user knows what was copied.
        button.image = nil
        button.title = char
        button.toolTip = "\(char) copied — press ⌘V to paste"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            button.title = ""
            button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Better Emoji")
            button.toolTip = "Better Emoji  \(self?.shortcutDisplayString() ?? "")"
            // Nudge the user to grant Accessibility once, so future picks auto-paste.
            if !AXIsProcessTrusted() { self?.nudgeAccessibility() }
        }
    }

    /// One-time nudge via a non-blocking alert.
    private var hasNudgedAccessibility = false
    private func nudgeAccessibility() {
        guard !hasNudgedAccessibility else { return }
        hasNudgedAccessibility = true
        let alert = NSAlert()
        alert.messageText = "Enable auto-paste"
        alert.informativeText = "Grant Accessibility access so Better Emoji can type emoji directly into any app — just like the system picker."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Inserter.requestAccessibility()
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if let button = statusItem?.button, let win = button.window {
            togglePanel(anchor: win.convertToScreen(button.convert(button.bounds, to: nil)))
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        // Open item — shows the keyboard shortcut in the menu
        let open = NSMenuItem(title: "Open Better Emoji", action: #selector(toggle), keyEquivalent: " ")
        open.keyEquivalentModifierMask = [.control, .option]
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        // Accessibility / paste status
        if Inserter.canPaste {
            let ok = NSMenuItem(title: "✓ Typing into active app", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        } else {
            let enable = NSMenuItem(title: "Enable Auto-Paste (Accessibility)…", action: #selector(requestAccessibility), keyEquivalent: "")
            enable.target = self
            menu.addItem(enable)
            let hint = NSMenuItem(title: "     Without it, emoji are copied to clipboard", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // back to click-to-toggle
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func requestAccessibility() {
        Inserter.requestAccessibility()
    }

    // MARK: - Panel

    @objc private func toggle() { togglePanel(anchor: nil) }

    private func togglePanel(anchor: NSRect?) {
        if panel.isVisible {
            panel.hide()
        } else {
            panel.show(anchor: anchor)
            panelState.shownCount += 1
        }
    }
}
