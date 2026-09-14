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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem!
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
            alert.messageText = "Emoji Search can't start"
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
        panel.onHide = { [weak self] in self?.engine.query = "" }

        panelState.onPick = { [weak self] _, char in
            self?.panel.hide()
            Inserter.insert(char)
        }
        panelState.onDismiss = { [weak self] in self?.panel.hide() }

        setUpStatusItem()
        // ⌃⌥Space — the system picker owns ⌃⌘Space and 🌐, so sit next to it.
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.toggle()
        }
        let args = CommandLine.arguments
        if args.contains("--show") { toggle() }
        // `--snapshot out.png [query]`: show, wait for the model, optionally search,
        // render the panel to a PNG and quit. Lets us eyeball the UI headlessly.
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
            let path = args[i + 1]
            let query = args.count > i + 2 ? args[i + 2] : ""
            toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                // Type it through the responder chain so focus handling is exercised too.
                for ch in query { typeKey(String(ch)) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    snapshot(to: path)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func typeKey(_ chars: String) {
        for down in [true, false] {
            guard let ev = NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0
            ) else { continue }
            panel.sendEvent(ev)
        }
    }

    private func snapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
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

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Emoji Search")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Emoji Search", action: #selector(toggle), keyEquivalent: " ")
        open.keyEquivalentModifierMask = [.control, .option]
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let paste = NSMenuItem(
            title: Inserter.canPaste ? "Pastes into the active app ✓" : "Enable Paste into Active App…",
            action: Inserter.canPaste ? nil : #selector(requestAccessibility),
            keyEquivalent: ""
        )
        paste.target = self
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Emoji Search", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // back to click-to-toggle
    }

    @objc private func requestAccessibility() {
        Inserter.requestAccessibility()
    }

    // MARK: - Panel

    @objc private func toggle() {
        if panel.isVisible {
            panel.hide()
        } else {
            panel.show()
            panelState.shownCount += 1
        }
    }
}
