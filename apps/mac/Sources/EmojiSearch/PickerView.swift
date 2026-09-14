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
    static let cellSize: CGFloat = 56
    static let width: CGFloat = 364
    static let height: CGFloat = 480
    static let cornerRadius: CGFloat = 20

    @EnvironmentObject private var engine: SearchEngine
    @EnvironmentObject private var panel: PanelState
    @FocusState private var searchFocused: Bool
    @State private var hovered: Emoji?
    @State private var category: Category = .smileys
    @State private var selection: Int?
    @State private var recent: [Emoji] = []

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
            selection = nil
            hovered = nil
            searchFocused = true
        }
        .onChange(of: engine.query) { _, _ in selection = nil }
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
                .onKeyPress(.downArrow) { move(by: Self.columns); return .handled }
                .onKeyPress(.upArrow) { move(by: -Self.columns); return .handled }
                .onKeyPress(.leftArrow) { selection == nil ? .ignored : moveHandled(by: -1) }
                .onKeyPress(.rightArrow) { selection == nil ? .ignored : moveHandled(by: 1) }
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
                if let s { proxy.scrollTo(s) }
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
        let highlighted = selection == position || (selection == nil && hovered == e)
        return Text(e.char)
            .font(.system(size: 36))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(highlighted ? Color.accentColor.opacity(0.22) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = e } else if hovered == e { hovered = nil }
            }
            .onTapGesture { pick(e, e.char) }
            .contextMenu {
                if !e.skins.isEmpty {
                    ForEach([e.char] + e.skins, id: \.self) { variant in
                        Button(variant) { pick(e, variant) }
                    }
                } else {
                    Button("Copy \(e.char)") { pick(e, e.char) }
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
                Text(hovered.map { $0.name.capitalized } ?? statusText)
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

    private func pickSelected() {
        let list = visible
        guard let e = selection.flatMap({ list.indices.contains($0) ? list[$0] : nil }) ?? (searching ? list.first : nil) else { return }
        pick(e, e.char)
    }

    private func pick(_ e: Emoji, _ char: String) {
        engine.store.touchRecent(e)
        panel.onPick(e, char)
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
