import SwiftUI
import ServiceManagement
import Carbon

// Internal notifications
extension Notification.Name {
    static let shortcutChanged        = Notification.Name("EmojiSearchShortcutChanged")
    static let menuBarVisibilityChanged = Notification.Name("EmojiSearchMenuBarVisibilityChanged")
}

// MARK: - Window Controller

/// Regular activating window shown when the user opens the app from Finder.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Better Emoji"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.minSize = NSSize(width: 480, height: 520)
        win.setContentSize(NSSize(width: 480, height: 580))
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // Temporarily become a regular app so the window gets a Dock tile and focus.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Retreat back to menu-bar-only mode when the window is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    // ── Persisted prefs ────────────────────────────────────────────────────
    @AppStorage("showMenuBarIcon")  private var showMenuBarIcon  = true
    @AppStorage("shortcutKeyCode")  private var shortcutKeyCode  = 49   // kVK_Space
    @AppStorage("shortcutCtrl")     private var shortcutCtrl     = true
    @AppStorage("shortcutOpt")      private var shortcutOpt      = true
    @AppStorage("shortcutShift")    private var shortcutShift    = false
    @AppStorage("shortcutCmd")      private var shortcutCmd      = false

    // ── Transient state ────────────────────────────────────────────────────
    @State private var launchAtLogin        = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var isRecordingShortcut  = false
    @StateObject private var updater        = UpdateChecker()

    private let version   = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    private let githubURL = URL(string: "https://github.com/haxzie/better-emoji")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Form {
                    generalSection
                    shortcutSection
                    permissionsSection
                    updateSection
                }
                .formStyle(.grouped)
            }
            .frame(minHeight: 360)
            Divider()
            footer
        }
        .frame(width: 480)
        .onAppear { accessibilityGranted = AXIsProcessTrusted() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSImage(byReferencing: Bundle.module.url(forResource: "logo", withExtension: "png")!))
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Better Emoji")
                    .font(.title2.bold())
                Text("Semantic emoji picker for macOS")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: General

    private var generalSection: some View {
        Section {
            // Launch at login
            LabeledContent {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch).labelsHidden()
                    .onChange(of: launchAtLogin) { _, on in applyLaunchAtLogin(on) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("Open automatically when you log in")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "power") }
            }

            // Menu bar icon
            LabeledContent {
                Toggle("", isOn: $showMenuBarIcon)
                    .toggleStyle(.switch).labelsHidden()
                    .onChange(of: showMenuBarIcon) { _, _ in
                        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
                    }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Menu Bar Icon")
                        if !showMenuBarIcon {
                            Text("The keyboard shortcut is your only way to open the picker")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("Access Better Emoji from the menu bar")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: { Image(systemName: "menubar.rectangle") }
            }
        } header: { Text("General") }
    }

    // MARK: Shortcut

    private var shortcutSection: some View {
        Section {
            LabeledContent {
                ShortcutRecorderField(
                    keyCode: $shortcutKeyCode, ctrl: $shortcutCtrl,
                    opt: $shortcutOpt, shift: $shortcutShift, cmd: $shortcutCmd,
                    isRecording: $isRecordingShortcut
                )
                .frame(width: 150, height: 28)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Emoji Picker")
                        Text("Global shortcut — works in any app")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "keyboard") }
            }
        } header: { Text("Keyboard Shortcut") }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        Section {
            LabeledContent {
                if accessibilityGranted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Button("Grant Access") {
                        Inserter.requestAccessibility()
                        pollAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text(accessibilityGranted
                             ? "Emoji is inserted directly into any text field"
                             : "Required to paste emoji into the active app — without this, emoji is only copied to clipboard")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: { Image(systemName: "hand.raised") }
            }
        } header: { Text("Permissions") }
    }

    // MARK: Update

    @ViewBuilder
    private var updateSection: some View {
        Section {
            switch updater.state {

            case .idle:
                LabeledContent {
                    Button("Check for Updates") { updater.check() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } label: {
                    Label {
                        Text("Software Update")
                    } icon: { Image(systemName: "arrow.down.circle") }
                }

            case .checking:
                LabeledContent {
                    ProgressView().controlSize(.small)
                } label: {
                    Label("Checking…", systemImage: "arrow.down.circle")
                }

            case .upToDate:
                Label("You're up to date ✓", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .available(let ver, let notes, let htmlUrl, let zipUrl):
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("v\(ver) is available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor).font(.headline)
                        Spacer()
                        Text("You have v\(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    HStack(spacing: 8) {
                        if let zip = zipUrl {
                            Button("Update Now") { updater.install(zipUrl: zip, htmlUrl: htmlUrl) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        Button(zipUrl == nil ? "Open Releases Page" : "View Release Notes") {
                            NSWorkspace.shared.open(URL(string: htmlUrl)!)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)

            case .downloading(let progress, let total):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Downloading update…", systemImage: "arrow.down.circle")
                        Spacer()
                        if total > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

            case .installing:
                Label("Installing… the app will relaunch", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)

            case .failed(let msg):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Update failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                    Button("Try Again") { updater.retry() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        } header: { Text("Updates") }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("v\(version)")
                .font(.caption).foregroundStyle(.tertiary)

            Spacer()

            Link("View on GitHub", destination: githubURL)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            print("Launch at login:", error.localizedDescription)
        }
    }

    private func pollAccessibility() {
        var tries = 0
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if AXIsProcessTrusted() { accessibilityGranted = true }
                else if tries < 24 { tries += 1; check() }
            }
        }
        check()
    }

}

// MARK: - Shortcut Recorder

/// SwiftUI wrapper around ShortcutRecorderView.
struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var ctrl: Bool
    @Binding var opt: Bool
    @Binding var shift: Bool
    @Binding var cmd: Bool
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        // Capture the projected-value Bindings so the closure can mutate them
        // even though `self` is a value type in NSViewRepresentable.
        let bKeyCode    = $keyCode
        let bCtrl       = $ctrl
        let bOpt        = $opt
        let bShift      = $shift
        let bCmd        = $cmd
        let bIsRec      = $isRecording
        v.onCapture = { kc, c, o, s, m in
            bKeyCode.wrappedValue    = kc
            bCtrl.wrappedValue       = c
            bOpt.wrappedValue        = o
            bShift.wrappedValue      = s
            bCmd.wrappedValue        = m
            bIsRec.wrappedValue      = false
            NotificationCenter.default.post(name: .shortcutChanged, object: nil)
        }
        return v
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.storedKeyCode = keyCode
        view.ctrl = ctrl; view.opt = opt; view.shift = shift; view.cmd = cmd
        view.isRecording = isRecording
        if isRecording { view.window?.makeFirstResponder(view) }
        view.needsDisplay = true
    }
}

/// Custom NSView that draws a shortcut badge and goes into recording mode on click.
final class ShortcutRecorderView: NSView {
    var storedKeyCode = 49
    var ctrl = true, opt = true, shift = false, cmd = false
    var isRecording = false
    var onCapture: ((Int, Bool, Bool, Bool, Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView:      Bool { true }

    private var displayLabel: String {
        if isRecording { return "Press shortcut…" }
        var s = ""
        if ctrl  { s += "⌃" }
        if opt   { s += "⌥" }
        if shift { s += "⇧" }
        if cmd   { s += "⌘" }
        s += keyName(storedKeyCode)
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let bg: NSColor     = isRecording ? accent.withAlphaComponent(0.10) : .quaternaryLabelColor.withAlphaComponent(0.18)
        let border: NSColor = isRecording ? accent : .separatorColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        bg.setFill(); path.fill()
        border.setStroke(); path.lineWidth = isRecording ? 1.5 : 1; path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording ? accent : NSColor.labelColor,
        ]
        let s = displayLabel as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                           y: (bounds.height - sz.height) / 2 + 1),
               withAttributes: attrs)
    }

    override func mouseDown(with _: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        let kc = Int(event.keyCode)
        // Ignore bare modifier presses
        let modifierKeyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeyCodes.contains(kc) { return }
        // Must have at least one modifier
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return }
        onCapture?(kc, flags.contains(.control), flags.contains(.option),
                   flags.contains(.shift), flags.contains(.command))
    }

    override func flagsChanged(with _: NSEvent) {
        if isRecording { needsDisplay = true }
    }

    // Maps a Carbon keyCode to a human-readable string using the current keyboard layout.
    private func keyName(_ code: Int) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 53: return "⎋"
        case 126: return "↑"; case 125: return "↓"
        case 123: return "←"; case 124: return "→"
        case 115: return "↖"; case 119: return "↘"
        default:
            guard
                let src  = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                let ptr  = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
            else { return "?" }
            let data  = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { return "?" }
            return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                var dead: UInt32 = 0
                var buf  = [UniChar](repeating: 0, count: 4)
                var len  = 0
                UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown),
                               0, UInt32(LMGetKbdType()),
                               UInt32(kUCKeyTranslateNoDeadKeysBit),
                               &dead, buf.count, &len, &buf)
                return len > 0 ? String(buf[0]).uppercased() : "?"
            }
        }
    }
}
