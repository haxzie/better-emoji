import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI
import os
@preconcurrency import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
    private var updateSub: AnyCancellable?
    private var updateTimer: Timer?

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
            let pasted = Inserter.insert(char, into: self?.panel.targetApp)
            if !pasted { self?.showCopiedFeedback(char) }
        }
        panelState.onDismiss = { [weak self] in self?.panel.hide() }

        if UserDefaults.standard.object(forKey: "showMenuBarIcon") == nil {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        }
        // First launch: register as a login item. Only ever done once, so turning it
        // off in Settings sticks.
        if !UserDefaults.standard.bool(forKey: "didDefaultLaunchAtLogin") {
            UserDefaults.standard.set(true, forKey: "didDefaultLaunchAtLogin")
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        }
        if UserDefaults.standard.bool(forKey: "showMenuBarIcon") { setUpStatusItem() }

        registerHotKey()
        setUpUpdateChecks()

        // Re-register the hotkey and toggle the status bar icon when settings change.
        NotificationCenter.default.addObserver(self, selector: #selector(applyShortcutChange),
                                               name: .shortcutChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyMenuBarChange),
                                               name: .menuBarVisibilityChanged, object: nil)

        let args = CommandLine.arguments
        let isCLI = args.contains("--show") || args.contains("--snapshot")

        // On first launch (or whenever Accessibility isn't granted yet), prompt the user so
        // emoji insertion works like the system picker — no separate "Enable" step required.
        // Not in the harness: the system dialog takes key from the panel and hides it.
        if !AXIsProcessTrusted() && !isCLI {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Inserter.requestAccessibility()
            }
        }
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
        // Arrow glyphs in the harness string become real arrow key events.
        let arrows: [String: (UInt16, String)] = [
            "↓": (125, "\u{F701}"), "↑": (126, "\u{F700}"), "←": (123, "\u{F702}"), "→": (124, "\u{F703}"),
        ]
        if let (code, fn) = arrows[chars] {
            for down in [true, false] {
                if let ev = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [.function, .numericPad],
                                             timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                             characters: fn, charactersIgnoringModifiers: fn, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(ev)
                }
            }
            return
        }
        // Real ⌃/⌘ key events carry the control character in `characters`.
        let characters = modifiers.contains(.control)
            ? String(chars.unicodeScalars.compactMap { Unicode.Scalar($0.value & 0x1F) }.map(Character.init))
            : chars
        for down in [true, false] {
            guard let ev = NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: chars, isARepeat: false,
                keyCode: chars == "\r" ? 36 : chars == "\u{1B}" ? 53 : 0  // ⏎ and ⎋ need their real key codes
            ) else { continue }
            NSApp.sendEvent(ev)
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
        guard let cg = CGWindowListCreateImage(quartz, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.bestResolution]) else {
            FileHandle.standardError.write("snapshot: no image (visible=\(panel.isVisible) alpha=\(panel.alphaValue) frame=\(f) win=\(panel.windowNumber))\n".data(using: .utf8)!)
            return
        }
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

    // MARK: - Updates

    /// Checks shortly after launch and every 6 h. A new version badges the tray icon,
    /// adds an "Update to vX" item to its menu, and posts one notification per version.
    private func setUpUpdateChecks() {
        let checker = UpdateChecker.shared
        // Map the emitted value: @Published fires on willSet, so reading the checker's
        // property here would see the previous state.
        updateSub = checker.$state
            .map { state -> String? in
                if case .available(let v, _, _, _, _) = state { return v }
                return nil
            }
            .removeDuplicates()
            .sink { [weak self] version in self?.updateAvailabilityChanged(version) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { checker.checkInBackground() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in checker.checkInBackground() }
        }

        // Only a real .app can talk to the notification center; the bare binary the
        // snapshot harness runs would crash on UNUserNotificationCenter.current().
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    private func updateAvailabilityChanged(_ version: String?) {
        Logger(subsystem: "com.haxzie.better-emoji", category: "updates").info("available: \(version ?? "none", privacy: .public)")
        refreshStatusItemBadge()
        guard let version else { return }
        let key = "notifiedUpdateVersion"
        guard UserDefaults.standard.string(forKey: key) != version,
              Bundle.main.bundleURL.pathExtension == "app" else { return }

        // Provisional: delivered quietly to Notification Center with no permission
        // dialog. The tray badge and menu item are the primary cue; this is a record.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .provisional]) { granted, error in
            Logger(subsystem: "com.haxzie.better-emoji", category: "updates").info("notification auth granted=\(granted) \(error.map { "\($0)" } ?? "", privacy: .public)")
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Better Emoji \(version) is available"
            content.body = "Click to install the update."
            center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)) { err in
                Logger(subsystem: "com.haxzie.better-emoji", category: "updates").info("notification posted: \(err.map { "\($0)" } ?? "ok", privacy: .public)")
                // Only remember it once it's actually been shown, so a denied or failed
                // attempt doesn't silence this version forever.
                if err == nil { UserDefaults.standard.set(version, forKey: key) }
            }
        }
    }

    /// Orange dot next to the tray icon while an update is waiting.
    private func refreshStatusItemBadge() {
        guard let button = statusItem?.button else { return }
        if let v = UpdateChecker.shared.availableVersion {
            button.attributedTitle = NSAttributedString(string: " ●", attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.systemFont(ofSize: 7),
                .baselineOffset: 5,
            ])
            button.toolTip = "Better Emoji — update to \(v) available"
        } else {
            button.title = ""
            button.toolTip = "Better Emoji  \(shortcutDisplayString())"
        }
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
        // ⌘Q from the settings window just closes it — the hotkey keeps working. Actually
        // quitting is the tray menu's job (and ⌘Q still quits if no window is open).
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit Better Emoji", action: #selector(closeWindowOrQuit), keyEquivalent: "q")

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
            self?.refreshStatusItemBadge()
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

        if let v = UpdateChecker.shared.availableVersion {
            let update = NSMenuItem(title: "Update to \(v)…", action: #selector(openSettings), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(update)
            menu.addItem(.separator())
        }

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
        let hide = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideMenuBarIcon), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        let hideHint = NSMenuItem(title: "     Open the app from Finder to get it back", action: nil, keyEquivalent: "")
        hideHint.isEnabled = false
        menu.addItem(hideHint)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // back to click-to-toggle
    }

    @objc private func hideMenuBarIcon() {
        UserDefaults.standard.set(false, forKey: "showMenuBarIcon")
        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
    }

    @objc private func closeWindowOrQuit() {
        if let win = SettingsWindowController.shared.window, win.isVisible {
            win.performClose(nil)
        } else {
            NSApp.terminate(nil)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func requestAccessibility() {
        Inserter.requestAccessibility()
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            SettingsWindowController.shared.show()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])  // show even while we're the active app
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
