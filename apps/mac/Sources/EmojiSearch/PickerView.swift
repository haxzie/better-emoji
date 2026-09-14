import SwiftUI

/// Shared between the AppKit panel and the SwiftUI view.
@MainActor
final class PanelState: ObservableObject {
    /// Bumped every time the panel is shown so the view can refocus the search field.
    @Published var shownCount = 0
    var onPick: (Emoji, String) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}
}

struct PickerView: View {
    static let columns = 6
    static let cellSize: CGFloat = 52
    static let width: CGFloat = 340
    static let height: CGFloat = 480
    static let cornerRadius: CGFloat = 20

    @EnvironmentObject private var engine: SearchEngine
    @EnvironmentObject private var panel: PanelState
    @FocusState private var searchFocused: Bool
    @State private var category: Category = .smileys
    /// Always points at something (the first emoji by default) so ⏎ inserts it.
    /// Hover moves it; ↑↓ move it and start keyboard navigation.
    @State private var selection: Int?
    /// True once ↑/↓ has been pressed: ←/→ then move the selection instead of the text
    /// cursor, and selection changes scroll the grid.
    @State private var navigating = false
    @State private var recent: [Emoji] = []
    /// Cell showing the "picked" check while the panel lingers before closing.
    @State private var picked: Int?

    private struct Section: Identifiable {
        let category: Category
        let start: Int
        let emoji: [Emoji]
        var id: Int { category.rawValue }
    }

    private var searching: Bool { !engine.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var sections: [Section] {
        var out: [Section] = []
        var pos = 0
        func add(_ c: Category, _ list: [Emoji]) {
            guard !list.isEmpty else { return }
            out.append(Section(category: c, start: pos, emoji: list))
            pos += list.count
        }
        if searching {
            add(.smileys, engine.results)  // category is irrelevant here; one flat list
        } else {
            add(.recent, recent)
            for c in Category.allCases where c != .recent { add(c, engine.store.byGroup[c] ?? []) }
        }
        return out
    }

    private var visible: [Emoji] { sections.flatMap(\.emoji) }

    var body: some View {
        // The grid runs the full height; the bars float over it on a blur that fades
        // into the emoji, so scrolled content dissolves under them instead of hitting a line.
        grid
            .safeAreaInset(edge: .top, spacing: 0) {
                searchBar
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(ProgressiveBlur(edge: .top).padding(.bottom, -28).allowsHitTesting(false))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
                    .background(ProgressiveBlur(edge: .bottom).padding(.top, -28).allowsHitTesting(false))
            }
        .frame(width: Self.width, height: Self.height)
        .modifier(PanelChrome())
        .onAppear { recent = engine.store.recent }
        .onChange(of: panel.shownCount) { _, _ in
            recent = engine.store.recent
            selection = 0
            navigating = false
            searchFocused = true
        }
        .onChange(of: engine.query) { _, _ in selection = 0; navigating = false }
        .onChange(of: engine.results.count) { _, _ in if !navigating { selection = 0 } }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search Emoji", text: $engine.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($searchFocused)
                .onKeyPress(.downArrow) { navigating = true; move(by: Self.columns); return .handled }
                .onKeyPress(.upArrow) { navigating = true; move(by: -Self.columns); return .handled }
                .onKeyPress(.leftArrow) { navigating ? moveHandled(by: -1) : .ignored }
                .onKeyPress(.rightArrow) { navigating ? moveHandled(by: 1) : .ignored }
                .onKeyPress(.return) { pickSelected(); return .handled }
                .onKeyPress(.escape) {
                    if searching { engine.query = "" } else { panel.onDismiss() }
                    return .handled
                }
            if searching {
                Button { engine.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.55)))
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if searching && engine.results.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(Self.cellSize), spacing: 2), count: Self.columns),
                        alignment: .leading,
                        spacing: 2,
                        pinnedViews: []
                    ) {
                        ForEach(sections) { section in
                            SwiftUI.Section {
                                ForEach(Array(section.emoji.enumerated()), id: \.offset) { i, e in
                                    cell(e, position: section.start + i)
                                }
                            } header: {
                                if !searching { sectionHeader(section.category) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: category) { _, c in
                guard !searching else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(c, anchor: .top) }
            }
            .onChange(of: selection) { _, s in
                if navigating, let s { proxy.scrollTo(s) }
            }
        }
    }

    private func sectionHeader(_ c: Category) -> some View {
        Text(c.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .id(c)
    }

    private func cell(_ e: Emoji, position: Int) -> some View {
        let highlighted = selection == position
        return Text(e.char)
            .font(.system(size: 32))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .background(
                // Same fill as the search field so the two read as one system.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(highlighted ? 0.55 : 0))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { selection = position }
            }
            .overlay { if picked == position { PickedBadge() } }
            .onTapGesture { pick(e, e.char, at: position) }
            .contextMenu {
                if !e.skins.isEmpty {
                    ForEach([e.char] + e.skins, id: \.self) { variant in
                        Button(variant) { pick(e, variant, at: position) }
                    }
                } else {
                    Button("Copy \(e.char)") { pick(e, e.char, at: position) }
                }
            }
            .id(position)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No emoji found")
                .foregroundStyle(.secondary)
            if engine.semantic == .loading {
                Text("Semantic search is still loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 4) {
            HStack {
                Text(selectedEmoji.map { $0.name.capitalized } ?? statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            HStack(spacing: 2) {
                ForEach(Category.allCases) { c in
                    categoryButton(c)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private var statusText: String {
        switch engine.semantic {
        case .loading: return "Loading semantic search…"
        case .ready:
            if let ms = engine.lastQueryMs { return "Semantic + keyword · \(Int(ms.rounded())) ms" }
            return "Semantic search ready"
        case .failed(let m): return "Keyword only — \(m)"
        }
    }

    private func categoryButton(_ c: Category) -> some View {
        let active = !searching && category == c
        return Button {
            if searching { engine.query = "" }
            category = c
        } label: {
            Image(systemName: c.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(active ? 1 : 0)))
                .foregroundStyle(active ? .primary : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.title)
    }

    // MARK: - Actions

    private func move(by delta: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let next = (selection ?? (delta > 0 ? -1 : 0)) + delta
        selection = min(max(next, 0), list.count - 1)
    }

    private func moveHandled(by delta: Int) -> KeyPress.Result {
        move(by: delta)
        return .handled
    }

    private var selectedEmoji: Emoji? {
        let list = visible
        guard let s = selection, list.indices.contains(s) else { return nil }
        return list[s]
    }

    private func pickSelected() {
        guard let e = selectedEmoji ?? visible.first else { return }
        pick(e, e.char, at: selectedEmoji == nil ? 0 : selection ?? 0)
    }

    /// Flash the check on the cell, then hand off (which closes the panel and inserts).
    private func pick(_ e: Emoji, _ char: String, at position: Int) {
        guard picked == nil else { return }  // already on the way out
        engine.store.touchRecent(e)
        picked = position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            panel.onPick(e, char)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { picked = nil }
        }
    }
}

/// Panel background: Liquid Glass on macOS 26+, translucent material before that.
/// Only the panel itself is glass — controls inside sit on it with flat fills,
/// per Apple's guidance not to stack glass on glass.
private struct PanelChrome: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: PickerView.cornerRadius, style: .continuous)

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.quaternary))
        }
    }
}

/// A within-window blur whose mask fades out toward the grid — the "progressive blur"
/// under the search bar and the tab bar. Built on NSVisualEffectView because SwiftUI's
/// materials can't be gradient-masked on macOS.
private struct ProgressiveBlur: NSViewRepresentable {
    enum Edge { case top, bottom }
    let edge: Edge

    /// The blur overhangs the grid; it must never eat clicks meant for the emoji under it.
    final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = PassthroughEffectView()
        v.blendingMode = .withinWindow
        v.material = .hudWindow
        v.state = .active
        // 1pt-wide gradient stretched over the view: solid at the bar's edge, clear at the grid.
        let mask = NSImage(size: NSSize(width: 1, height: 64), flipped: false) { rect in
            let solidEnd: [NSColor] = [.clear, .black.withAlphaComponent(0.85), .black]  // bottom → top
            let colors = edge == .top ? solidEnd : solidEnd.reversed()
            NSGradient(colors: colors, atLocations: [0, 0.45, 1], colorSpace: .deviceRGB)?
                .draw(in: rect, angle: 90)
            return true
        }
        mask.resizingMode = .stretch
        v.maskImage = mask
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Green check in a translucent ring, springing up over the emoji that was just picked.
private struct PickedBadge: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.35))
            Circle()
                .strokeBorder(.white.opacity(0.55), lineWidth: 2)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
        }
        .frame(width: 44, height: 44)
        .scaleEffect(shown ? 1 : 0.4)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { shown = true }
        }
    }
}
