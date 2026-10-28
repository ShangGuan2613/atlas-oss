import AppKit
import AtlasCore
import SwiftUI

/// The detail pane: **Grid** (pointer-anchored density zoom, multi-select, keyboard cursor)
/// or **Canvas** (free placement on a persisted board), sharing one selection and one
/// lightbox. Still read-only, and still a single `LazyVGrid` for the grid path — the
/// NSCollectionView rewrite belongs to P1f.
struct ContentView: View {
    @EnvironmentObject private var model: LibraryModel
    /// Capture funnel (P1-E). Drops and ⌘V go through it so every surface reports the same way.
    @EnvironmentObject private var capture: CaptureCenter
    /// Design tokens (P1-D). Read from the environment so a Settings change lands here
    /// without this view knowing where the values came from.
    @Environment(\.appearance) private var tokens

    @AppStorage("grid.cellWidth") private var cellWidth: Double = GridDensity.defaultCellWidth
    /// Info inspector visibility, remembered across launches (P1-C).
    @AppStorage("info.panelVisible") private var showInfo: Bool = false
    /// Grid | Canvas | Infinity (P2-B), remembered across launches. One global mode: switching
    /// collection keeps the surface (per-collection memory is still open — see STATUS).
    @AppStorage("view.mode") private var viewMode: ViewMode = .grid

    @State private var itemSelection = ItemSelection()
    @State private var cellFrames: [UUID: CGRect] = [:]
    @State private var pendingAnchor: PendingAnchor?
    @State private var lightboxID: UUID?
    @State private var savedOffset: CGFloat = 0
    @State private var pointer: CGPoint?
    @State private var viewport: CGSize = .zero
    @State private var magnifyBase: Double?
    @State private var gridEngaged = false
    /// True while a file drag is over the detail pane — drives the drop highlight.
    @State private var isDropTargeted = false

    @StateObject private var scroll = GridScrollController()
    @StateObject private var events = GridEventMonitor()
    /// Canvas camera + transient board interaction state (P2-A). Owned here so the toolbar can
    /// refit the camera after Reset Layout without reaching into the board view.
    @StateObject private var canvasBoard = CanvasBoardState()
    /// Retained while the optional P1f scroll probe runs.
    @State private var scrollProbe: GridScrollProbe?

    private static let gridSpace = "atlas.grid"

    /// Zoom captured before a layout change, replayed once the new frames arrive.
    private struct PendingAnchor: Equatable {
        let anchor: GridAnchor
        let pointerY: CGFloat
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
            } detail: {
                detail
            }
            .navigationTitle("AtlasOSS")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if viewMode.usesBoard {
                        Button {
                            performFit()
                        } label: {
                            Label("Fit", systemImage: "scope")
                        }
                        .help("Fit — frame this board's content (⌘⇧F)")

                        Button {
                            performResetLayout()
                        } label: {
                            Label("Reset Layout", systemImage: "rectangle.3.group")
                        }
                        .help("Reset layout — repack this board in the current sort order (⌘⇧R)")
                    }
                    viewSwitcher
                    Button {
                        showInfo.toggle()
                    } label: {
                        Label("Info", systemImage: "sidebar.right")
                    }
                    .help("Show info (I)")
                }
            }

            if let item = lightboxItem {
                LightboxView(
                    item: item,
                    url: model.fileURL(for: item),
                    index: lightboxIndex,
                    total: model.items.count,
                    onClose: closeLightbox,
                    onStep: stepLightbox
                )
                .zIndex(1)
            }

            // Capture feedback (P1-E). Above the lightbox: a drop can land while one is open.
            VStack {
                if let banner = capture.banner {
                    CaptureBannerView(banner: banner) { capture.dismissBanner() }
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.18), value: capture.banner)
            .zIndex(2)
        }
        .onAppear(perform: wireEvents)
        .onDisappear { events.stop() }
        .task { startScrollProbeIfRequested() }
        .onChange(of: model.selection) { _, _ in
            itemSelection.clear()
            closeLightbox()
            savedOffset = 0
        }
        .onChange(of: viewMode) { _, mode in
            // Switching to a board loads (or seeds) its layout and frames the content.
            guard mode.usesBoard else { return }
            model.reloadCanvasPositions()
            canvasBoard.needsFit = true
        }
        .onAppear {
            // A persisted mode could name something this build cannot show.
            viewMode = ViewMode.resolved(viewMode.rawValue)
        }
        .onChange(of: model.items) { _, items in
            itemSelection.prune(to: items.map(\.id))
            // Warm the palettes of what is on screen so the color filter and the Info
            // panel never stall on decoding (bounded inside the model).
            Task { await warmPalettes() }
        }
        .onChange(of: itemSelection) { _, selection in
            // Mirror the grid selection into the model: the Info panel, tag editing and the
            // color filter all read from there instead of owning a second selection.
            model.setSelection(model.items.map(\.id).filter { selection.isSelected($0) })
        }
        .task { await warmPalettes() }
    }

    /// P1-C palette extraction in the background. P1f's scroll probe measures the grid
    /// alone, so it is skipped during a probe run rather than double-counted.
    private func warmPalettes() async {
        guard !GridScrollProbe.isRequested else { return }
        await model.prefetchPalettes()
    }

    // MARK: - Frame probe (P1f, opt-in)

    /// Starts `GridScrollProbe` when `ATLAS_SCROLL_PROBE` is set. Waits for the grid to have
    /// items and a mounted `NSScrollView`, then lets the first paint settle so the numbers
    /// describe scrolling rather than launch.
    private func startScrollProbeIfRequested() {
        guard let duration = GridScrollProbe.requestedDuration else { return }
        Task { @MainActor in
            for _ in 0..<1_200 {
                if !model.items.isEmpty, scroll.attachedScrollView != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let clipView = scroll.attachedScrollView?.contentView else {
                print("P1F-SCROLL no scroll view attached after 60s")
                fflush(stdout)
                exit(0)
            }
            print("P1F-SCROLL library \(model.libraryPath) items=\(model.items.count) thumbs=\(model.thumbnailFileCount)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let probe = GridScrollProbe(scroll: scroll, duration: duration)
            scrollProbe = probe
            probe.start(on: clipView)
        }
    }

    // MARK: - Detail

    /// Grid plus the optional Info inspector. The pane is a trailing `HStack` child rather
    /// than `.inspector` so the grid keeps one `GeometryReader` and the P1-A
    /// pointer-anchored zoom maths stay untouched.
    private var detail: some View {
        HStack(spacing: 0) {
            detailContent
                // P1-E: the whole detail pane (grid, empty state, error state) is a drop
                // target, so an empty library is the *easiest* thing to drop onto rather
                // than the only thing that cannot be.
                .dropDestination(for: URL.self) { urls, _ in
                    handleFileDrop(urls)
                } isTargeted: { targeted in
                    isDropTargeted = targeted
                }
                .overlay { dropHighlight }
            if showInfo {
                Divider()
                infoPane
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                    .background(.thinMaterial)
            }
        }
    }

    // MARK: - Capture (P1-E)

    /// Where a drop from this window lands: the selected user collection (import *and*
    /// file), otherwise the Inbox.
    private var captureDecision: CaptureRouting.Decision {
        CaptureRouting.decision(for: model.selection, tree: model.tree)
    }

    @discardableResult
    private func handleFileDrop(_ urls: [URL]) -> Bool {
        let decision = captureDecision
        return capture.capture(urls: urls, target: decision.target, source: .windowDrop) != nil
    }

    /// Non-blocking "drop here" affordance. `allowsHitTesting(false)` so it can never eat
    /// the drop that summoned it.
    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTargeted {
            let decision = captureDecision
            RoundedRectangle(cornerRadius: tokens.largeRadius)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(
                    Color.accentColor.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: tokens.largeRadius)
                )
                .overlay(alignment: .center) {
                    Label("Add to \(decision.label)", systemImage: "arrow.down.circle.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                }
                .padding(tokens.contentPadding / 2)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let error = model.loadError {
            message(error, systemImage: "exclamationmark.triangle")
        } else if !model.isLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                detailHeader
                Divider()
                switch viewMode {
                case .grid:
                    grid
                case .canvas:
                    board(unbounded: false)
                case .infinity:
                    board(unbounded: true)
                }
            }
        }
    }

    private var infoPane: some View {
        InfoPanelView(
            summary: model.infoSummary,
            swatches: model.infoSwatches,
            tagBadges: model.info.tagBadges,
            collectionChips: model.info.collectionChips,
            previewURL: infoPreviewURL,
            addableTags: model.addableTags,
            isLoadingSwatches: model.info.isLoadingSwatches,
            onSelectTag: { model.select(.tag($0)) },
            onAddTag: { model.addTag($0) },
            onRemoveTag: { model.removeTag($0) },
            onSelectCollection: { model.select(.collection($0)) },
            onSelectColor: { hex in
                Task { await model.applyColorFilter(hex: hex) }
            },
            onClose: { showInfo = false }
        )
    }

    /// Preview is only meaningful for a single item; multi-selection deliberately skips it.
    private var infoPreviewURL: URL? {
        let targets = model.infoTargetItems
        guard targets.count == 1 else { return nil }
        return model.fileURL(for: targets[0])
    }

    /// Where you are, and how many. Kept outside the grid's `GeometryReader` so the
    /// pointer-anchored zoom maths in P1-A are untouched.
    private var detailHeader: some View {
        HStack(spacing: 8) {
            Text(model.selectionTitle)
                .font(.headline)
            Text("\(model.items.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let filter = model.info.colorFilter {
                // The active color filter lives on the detail header, so the way out of it
                // is always one click away.
                ColorFilterChip(hex: filter.hex, count: model.items.count) {
                    model.clearColorFilter()
                }
            }
            Spacer()
        }
        .padding(.horizontal, tokens.contentPadding)
        .padding(.vertical, 8)
    }

    // MARK: - View switcher (P2-A → P2-B)

    /// Grid | Canvas | Infinity. P2-A could not put Infinity in the segmented control (a segment
    /// cannot be disabled) and shipped a disabled button beside it; P2-B ships the mode, so the
    /// honest control is the one the pillarbox claimed it wanted: three segments.
    private var viewSwitcher: some View {
        Picker("View", selection: $viewMode) {
            ForEach(ViewMode.selectable) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Grid (⌘1) · Canvas (⌘2) · Infinity (⌘3)")
    }

    /// The board. Canvas bounds a drag to the board rect and draws its frame; Infinity bounds
    /// nothing. Selection, Space lightbox and persistence are shared with the Grid because they
    /// are three views of one library, not three modes.
    private func board(unbounded: Bool) -> some View {
        CanvasView(
            board: canvasBoard,
            selection: $itemSelection,
            unbounded: unbounded,
            onOpenLightbox: { id in openLightbox(id) }
        )
    }

    /// Toolbar / ⌘⇧R: repack the current board, then frame it.
    private func performResetLayout() {
        model.resetCanvasLayout()
        canvasBoard.resetCamera(content: model.canvasContentBounds)
    }

    /// Toolbar / ⌘⇧F: frame the content without moving a tile.
    ///
    /// This is the *soft* replacement for P2-A's camera clamp: Infinity deliberately lets the
    /// camera leave the content, so "find content" is an action rather than a constraint.
    private func performFit() {
        model.reloadCanvasPositions()
        canvasBoard.fit(content: model.canvasContentBounds)
    }

    private var grid: some View {
        GeometryReader { proxy in
            let columns = GridDensity.columns(
                availableWidth: proxy.size.width,
                cellWidth: cellWidth,
                spacing: tokens.spacing,
                padding: tokens.contentPadding
            )

            ScrollView {
                LazyVGrid(columns: gridColumns(columns), spacing: tokens.spacing) {
                    ForEach(model.items) { item in
                        ItemCell(
                            item: item,
                            request: model.thumbnailRequest(for: item),
                            cellWidth: cellWidth,
                            isSelected: itemSelection.isSelected(item.id)
                        )
                        .background(frameProbe(for: item.id))
                        .onTapGesture(count: 2) { handleClick(item, opensLightbox: true) }
                        .onTapGesture { handleClick(item) }
                        .onDrag { itemDragProvider(for: item) }
                    }
                }
                .frame(width: GridDensity.gridWidth(columns: columns, cellWidth: cellWidth, spacing: tokens.spacing), alignment: .leading)
                .padding(tokens.contentPadding)
                .background(ScrollOffsetBridge(controller: scroll).frame(width: 0, height: 0))
            }
            .background(tokens.backgroundFill ?? Color.clear)
            .coordinateSpace(name: Self.gridSpace)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): pointer = point
                case .ended: pointer = nil
                }
            }
            .simultaneousGesture(magnifyGesture)
            .onPreferenceChange(GridFramesKey.self, perform: applyFrames)
            .onChange(of: proxy.size) { _, size in viewport = size }
            .onAppear { viewport = proxy.size }
            .overlay(alignment: .bottom) { selectionBar }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { value in
                if magnifyBase == nil {
                    magnifyBase = cellWidth
                    pendingAnchor = makeAnchor()
                }
                guard let base = magnifyBase else { return }
                changeDensity(to: base * value.magnification, captureAnchor: false)
            }
            .onEnded { _ in magnifyBase = nil }
    }

    private func gridColumns(_ count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.fixed(cellWidth), spacing: tokens.spacing, alignment: .top),
            count: max(1, count)
        )
    }

    private func frameProbe(for id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: GridFramesKey.self, value: [id: geo.frame(in: .named(Self.gridSpace))])
        }
    }

    // MARK: - Multi-select chrome

    @ViewBuilder
    private var selectionBar: some View {
        if itemSelection.count >= 2 {
            HStack(spacing: 12) {
                Text("\(itemSelection.count) selected")
                    .font(.callout.weight(.medium))
                Divider().frame(height: 14)
                Button("Clear") { itemSelection.clear() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.15), value: itemSelection.count)
        }
    }

    // MARK: - Density

    /// Records the anchor *before* the layout changes; the scroll correction happens
    /// in `applyFrames` once the new cell frames are measured.
    private func changeDensity(to proposed: Double, captureAnchor: Bool) {
        let next = GridDensity.clamp(proposed)
        guard abs(next - cellWidth) > 0.01 else { return }
        if captureAnchor {
            pendingAnchor = makeAnchor()
        }
        cellWidth = next
    }

    private func makeAnchor() -> PendingAnchor? {
        let point = pointer ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        guard let anchor = GridAnchor.anchor(at: point, frames: cellFrames) else { return nil }
        return PendingAnchor(anchor: anchor, pointerY: point.y)
    }

    private func applyFrames(_ frames: [UUID: CGRect]) {
        cellFrames = frames
        guard let pending = pendingAnchor else { return }
        pendingAnchor = nil
        guard scroll.isAttached, let frame = frames[pending.anchor.itemID] else { return }
        scroll.setOffset(
            pending.anchor.targetOffset(
                currentOffset: scroll.offset,
                pointerY: pending.pointerY,
                newFrame: frame
            )
        )
    }

    private var currentColumns: Int {
        GridDensity.columns(
            availableWidth: viewport.width,
            cellWidth: cellWidth,
            spacing: tokens.spacing,
            padding: tokens.contentPadding
        )
    }

    /// Keeps the keyboard cursor inside the viewport.
    private func reveal(_ id: UUID) {
        guard let frame = cellFrames[id], viewport.height > 0, scroll.isAttached else { return }
        let margin: CGFloat = 12
        if frame.minY < margin {
            scroll.setOffset(scroll.offset + frame.minY - margin)
        } else if frame.maxY > viewport.height - margin {
            scroll.setOffset(scroll.offset + frame.maxY - viewport.height + margin)
        }
    }

    // MARK: - Selection

    /// Drags the whole selection when the dragged cell is part of it, otherwise just that
    /// cell. Ids are emitted in grid order so the drop handler sees a stable list.
    private func itemDragProvider(for item: AtlasCore.LibraryItem) -> NSItemProvider {
        let ids = itemSelection.isSelected(item.id)
            ? model.items.map(\.id).filter { itemSelection.isSelected($0) }
            : [item.id]
        let payload = SidebarDragPayload.items(ids.isEmpty ? [item.id] : ids).encoded
        return NSItemProvider(object: payload as NSString)
    }

    private func handleClick(_ item: AtlasCore.LibraryItem, opensLightbox: Bool = false) {
        gridEngaged = true
        if opensLightbox {
            itemSelection.select(item.id)
            openLightbox()
            return
        }

        // Modifier state at click time; SwiftUI's tap gestures do not report modifiers.
        let modifiers = NSEvent.modifierFlags
        let ids = model.items.map(\.id)
        if modifiers.contains(.shift) {
            itemSelection.extend(to: item.id, in: ids, additive: modifiers.contains(.command))
        } else if modifiers.contains(.command) {
            itemSelection.toggle(item.id)
        } else {
            itemSelection.select(item.id)
        }
    }

    // MARK: - Lightbox

    private var lightboxItem: AtlasCore.LibraryItem? {
        guard let lightboxID else { return nil }
        return model.items.first { $0.id == lightboxID }
    }

    private var lightboxIndex: Int {
        guard let lightboxID else { return 0 }
        return model.items.firstIndex { $0.id == lightboxID } ?? 0
    }

    private func openLightbox() {
        guard let id = itemSelection.focusedID ?? itemSelection.ids.first else { return }
        openLightbox(id)
    }

    /// Opens the shared lightbox on a specific item (Canvas double-click, Canvas Space tap).
    private func openLightbox(_ id: UUID) {
        guard lightboxID == nil, model.items.contains(where: { $0.id == id }) else { return }
        savedOffset = scroll.offset
        lightboxID = id
    }

    private func closeLightbox() {
        guard lightboxID != nil else { return }
        lightboxID = nil
        let restore = savedOffset
        DispatchQueue.main.async { scroll.setOffset(restore) }
    }

    private func stepLightbox(_ step: Int) {
        let items = model.items
        guard let id = lightboxID,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        let next = min(items.count - 1, max(0, index + step))
        guard next != index else { return }
        lightboxID = items[next].id
        itemSelection.select(items[next].id)
    }

    // MARK: - Events

    private func wireEvents() {
        events.handleKey = { handleKey($0) }
        events.handleScroll = { handleScroll($0) }
        events.start()
    }

    /// The monitor is app-wide, so shortcuts stand down while the sidebar list or a
    /// text control owns the keyboard.
    private var keyboardBelongsToAnotherControl: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTableView || responder is NSTextView
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if lightboxID != nil {
            switch event.keyCode {
            case GridKey.escape, GridKey.space:
                closeLightbox()
                return true
            case GridKey.leftArrow:
                stepLightbox(-1)
                return true
            case GridKey.rightArrow:
                stepLightbox(1)
                return true
            default:
                return false
            }
        }

        // The monitor is app-wide: while a text control owns the keyboard, every shortcut
        // here stands down (so typing "i" in a name field never toggles the panel).
        guard !keyboardBelongsToAnotherControl else { return false }

        // `I` toggles the inspector. Checked before the "grid engaged" guards so it works
        // on an empty view too, but never while the lightbox is open (that branch above
        // returns first).
        if !flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "i" {
            showInfo.toggle()
            return true
        }

        // ⌘V — Finder semantics: files/images on the pasteboard are imported, connected by
        // default. Placed before the empty-grid guards so pasting works as the first thing
        // you do in a new library. Text-only pasteboards return `nil` and fall through, so
        // this never swallows a copy into some other control.
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
            return capture.capturePasteboard(target: captureDecision.target) != nil
        }

        // View switcher: ⌘1 Grid, ⌘2 Canvas, ⌘3 Infinity (P2-B). Each digit is the mode it
        // has always meant; ⌘3 stops being swallowed now that there is something to show.
        if flags.contains(.command), let character = event.charactersIgnoringModifiers {
            switch character {
            case "1":
                viewMode = .grid
                return true
            case "2":
                viewMode = .canvas
                return true
            case "3":
                viewMode = .infinity
                return true
            default:
                break
            }
        }

        // ⌘⇧R resets the board layout (both board surfaces — the grid has none). ⌘⇧F (Fit)
        // belongs to the board's own monitor, which is the only place that knows its content.
        if flags.contains(.command), flags.contains(.shift),
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            guard viewMode.usesBoard else { return false }
            performResetLayout()
            return true
        }

        // Everything below is grid behaviour: the Canvas owns its own keys (Space arms
        // panning, Escape clears), so this handler stands down rather than answering twice.
        guard viewMode == .grid else { return false }

        guard !model.items.isEmpty else { return false }
        guard pointer != nil || gridEngaged else { return false }

        if flags.contains(.command) {
            guard event.charactersIgnoringModifiers?.lowercased() == "a" else { return false }
            itemSelection.selectAll(model.items.map(\.id))
            return true
        }

        switch event.keyCode {
        case GridKey.space:
            openLightbox()
            return true
        case GridKey.escape:
            guard !itemSelection.isEmpty else { return false }
            itemSelection.clear()
            return true
        case GridKey.leftArrow, GridKey.rightArrow, GridKey.upArrow, GridKey.downArrow:
            itemSelection.move(
                moveDirection(for: event.keyCode),
                in: model.items.map(\.id),
                columns: currentColumns,
                extending: flags.contains(.shift)
            )
            if let focused = itemSelection.focusedID {
                reveal(focused)
            }
            return true
        default:
            return false
        }
    }

    private func moveDirection(for keyCode: UInt16) -> GridMove {
        switch keyCode {
        case GridKey.leftArrow: return .left
        case GridKey.rightArrow: return .right
        case GridKey.upArrow: return .up
        default: return .down
        }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        // The Canvas runs its own monitor (scroll pans, ⌘-scroll zooms); answering here too
        // would change the grid density behind a board that is not visible.
        guard viewMode == .grid else { return false }
        guard lightboxID == nil, pointer != nil, event.modifierFlags.contains(.command) else { return false }
        changeDensity(
            to: GridDensity.stepped(
                cellWidth,
                delta: Double(event.scrollingDeltaY),
                precise: event.hasPreciseScrollingDeltas
            ),
            captureAnchor: true
        )
        return true
    }

    // MARK: - Placeholders

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No items in this view")
                .font(.headline)
            Text("Drop files here, or paste with ⌘V — connected by default.")
                .foregroundStyle(.secondary)
            Text("Or import a folder from the CLI:")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("atlasoss import <folder> --mode connected")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Text(model.libraryPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if model.info.colorFilter != nil {
                Button("Clear color filter") { model.clearColorFilter() }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
