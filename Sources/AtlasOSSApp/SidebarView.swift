import AppKit
import AtlasCore
import SwiftUI

/// Tree sidebar: pinned Inbox, nested collections with disclosure, and a tags section.
///
/// Built from plain SwiftUI stacks rather than `List` because every row is a drag source
/// *and* a positional drop target — `List`'s `NSTableView` backing swallows both.
struct SidebarView: View {
    @EnvironmentObject private var model: LibraryModel
    /// Capture funnel (P1-E): a file dropped on a row is imported and filed into it.
    @EnvironmentObject private var capture: CaptureCenter
    /// Row height and row/chip radii come from the design tokens (P1-D), so a density
    /// change reaches the tree and the drop-zone maths stay in sync (both read `rowHeight`).
    @Environment(\.appearance) private var tokens

    @State private var hoveredRowID: String?
    @State private var dropZone: [String: SidebarDropZone] = [:]
    /// Separate from `dropZone` on purpose: the two drop types (library items vs files) run
    /// independent `isTargeted` callbacks on the same row and would otherwise clear each
    /// other's highlight.
    @State private var fileDropRowID: String?
    @State private var naming: NamingRequest?

    /// Row height scales with the spacing token (`26` at the default density).
    private var rowHeight: CGFloat { CGFloat(tokens.sidebarRowHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                // VStack (not LazyVStack): per-row NSViewRepresentable drop
                // targets mis-recycle under LazyVStack and steal hits from upper rows.
                VStack(alignment: .leading, spacing: 1) {
                    inboxAndAllItems
                    Divider().padding(.vertical, 6)
                    collectionsSection
                    Divider().padding(.vertical, 6)
                    tagsSection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
        }
        .background(.thinMaterial)
        .sheet(item: $naming) { request in
            NameEntrySheet(request: request) { name in
                naming = nil
                commit(request, name: name)
            } onCancel: {
                naming = nil
            }
        }
        .onAppear {
            // Start expanded so nesting is visible; the model prunes stale ids on reload.
            model.expanded.formUnion(model.tree.flatMap { $0.flattened() }.map(\.id))
        }
    }

    // MARK: - Fixed rows

    private var inboxAndAllItems: some View {
        VStack(alignment: .leading, spacing: 1) {
            row(
                title: "Inbox",
                systemImage: "tray",
                count: model.inboxItemCount,
                isSelected: model.selection == .inbox,
                indent: 0,
                entry: .inbox
            )
            row(
                title: "All Items",
                systemImage: "square.grid.2x2",
                count: model.totalItemCount,
                isSelected: model.selection == .all,
                indent: 0,
                entry: .all
            )
        }
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader(
                "Collections",
                addHelp: "New folder",
                onAdd: { naming = NamingRequest(kind: .newCollection(parentID: nil), initial: "") }
            )
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let payload = SidebarDragPayload(raw: raw) else { return false }
                return model.apply(
                    SidebarTree.resolve(payload: payload, target: .root, zone: .onto, tree: model.tree)
                )
            }

            ForEach(collectionRows) { sidebarRow in
                collectionRowView(sidebarRow)
            }

            if collectionRows.isEmpty {
                Text("No folders yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
                    .padding(.vertical, 2)
            }
        }
    }

    /// Tree rows minus the Inbox, which is pinned in the fixed section above.
    private var collectionRows: [SidebarRow] {
        SidebarRow.rows(tree: model.tree, tags: [], expanded: model.expanded)
            .filter { $0.kind != .inbox }
    }

    @ViewBuilder
    private func collectionRowView(_ sidebarRow: SidebarRow) -> some View {
        let collection = sidebarRow.collectionID.flatMap(model.collection(for:)) 
        HStack(spacing: 0) {
            // Disclosure chevron
            Button {
                if let id = sidebarRow.collectionID { model.toggleExpansion(id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(sidebarRow.isExpanded ? 90 : 0))
                    .frame(width: 14, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(sidebarRow.hasChildren ? 1 : 0)
            .disabled(!sidebarRow.hasChildren)

            SidebarRowLabel(
                title: sidebarRow.title,
                systemImage: sidebarRow.kind == .inbox ? "tray" : "folder",
                count: sidebarRow.itemCount,
                isSelected: model.selection == sidebarRow.entry,
                isHovered: hoveredRowID == sidebarRow.id,
                tagColor: nil,
                zone: dropZone[sidebarRow.id] ?? fileDropZone(for: sidebarRow.id)
            )
        }
        .padding(.leading, CGFloat(sidebarRow.depth) * 12 + 2)
        .frame(height: rowHeight)
        // Inbox and All Items are pinned; only user folders are draggable.
        .modifier(CollectionDragModifier(payload: draggablePayload(for: sidebarRow, collection: collection)))
        .dropDestination(for: String.self) { items, location in
            guard let raw = items.first, let payload = SidebarDragPayload(raw: raw) else { return false }
            let target: SidebarDropTarget = collection.map(SidebarDropTarget.collection) ?? .root
            let zone = SidebarTree.zone(locationY: location.y, rowHeight: rowHeight)
            let action = SidebarTree.resolve(payload: payload, target: target, zone: zone, tree: model.tree)
            return model.apply(action)
        } isTargeted: { targeted in
            dropZone[sidebarRow.id] = targeted ? .onto : nil
        }
        // P1-E: files dragged from Finder (or any app) land here too. Dropping on a user
        // collection imports *and* files — the same end state as dropping an item row on it.
        //
        // This is an AppKit drop view placed *behind* the row, not a second
        // `dropDestination`: two typed drop modifiers on one view cancel each other out, which
        // would break the P1-B item drops above.
        .background(
            FileDropArea(
                onFiles: { urls in captureFiles(urls, into: collection) },
                onTargeted: { targeted in
                    if targeted {
                        fileDropRowID = sidebarRow.id
                    } else if fileDropRowID == sidebarRow.id {
                        fileDropRowID = nil
                    }
                }
            )
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredRowID = inside ? sidebarRow.id : (hoveredRowID == sidebarRow.id ? nil : hoveredRowID)
        }
        .onTapGesture { model.select(sidebarRow.entry) }
        .contextMenu { collectionMenu(sidebarRow) }
    }

    @ViewBuilder
    private func collectionMenu(_ sidebarRow: SidebarRow) -> some View {
        if let id = sidebarRow.collectionID, sidebarRow.kind != .inbox {
            Button("New Subfolder…") {
                naming = NamingRequest(kind: .newCollection(parentID: id), initial: "")
            }
            Button("Rename…") {
                naming = NamingRequest(kind: .renameCollection(id), initial: sidebarRow.title)
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteCollection(id) }
        } else {
            Button("New Folder…") {
                naming = NamingRequest(kind: .newCollection(parentID: nil), initial: "")
            }
        }
    }

    private func draggablePayload(for sidebarRow: SidebarRow, collection: LibraryCollection?) -> String? {
        guard sidebarRow.kind == .collection, let collection else { return nil }
        return SidebarDragPayload.collection(collection.id).encoded
    }

    /// Highlight state for a file drag, kept apart from the item-drag `dropZone`.
    private func fileDropZone(for rowID: String) -> SidebarDropZone? {
        fileDropRowID == rowID ? .onto : nil
    }

    /// Imports dropped files and files them into the hovered row.
    ///
    /// The Inbox (and any non-editable node) is a plain Inbox capture; a user collection
    /// gets `.assignedCollection`, which is the import+filing rule from P1-B.
    @discardableResult
    private func captureFiles(_ urls: [URL], into collection: LibraryCollection?) -> Bool {
        guard let collection, collection.isUserEditable else {
            return capture.capture(urls: urls, target: .inbox, source: .sidebarDrop) != nil
        }
        return capture.capture(
            urls: urls,
            target: .assignedCollection(collection.id),
            source: .sidebarDrop
        ) != nil
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader(
                "Tags",
                addHelp: "New tag",
                onAdd: { naming = NamingRequest(kind: .newTag, initial: "") }
            )
            ForEach(tagRows) { sidebarRow in
                SidebarRowLabel(
                    title: sidebarRow.title,
                    systemImage: "number",
                    count: sidebarRow.itemCount,
                    isSelected: model.selection == sidebarRow.entry,
                    isHovered: hoveredRowID == sidebarRow.id,
                    tagColor: nil,
                    zone: dropZone[sidebarRow.id]
                )
                .frame(height: rowHeight)
                .padding(.leading, 16)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first,
                          let payload = SidebarDragPayload(raw: raw),
                          let tagID = sidebarRow.tagID,
                          let tag = model.tag(for: tagID) else { return false }
                    let action = SidebarTree.resolve(
                        payload: payload, target: .tag(tag), zone: .onto, tree: model.tree
                    )
                    return model.apply(action)
                } isTargeted: { targeted in
                    dropZone[sidebarRow.id] = targeted ? .onto : nil
                }
                .contentShape(Rectangle())
                .onHover { inside in
                    hoveredRowID = inside ? sidebarRow.id : (hoveredRowID == sidebarRow.id ? nil : hoveredRowID)
                }
                .onTapGesture { model.select(sidebarRow.entry) }
                .contextMenu {
                    Button("Rename…") {
                        if let tagID = sidebarRow.tagID {
                            naming = NamingRequest(kind: .renameTag(tagID), initial: sidebarRow.title)
                        }
                    }
                    Button("Delete", role: .destructive) {
                        if let tagID = sidebarRow.tagID { model.deleteTag(tagID) }
                    }
                }
            }

            if tagRows.isEmpty {
                Text("No tags yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
                    .padding(.vertical, 2)
            }
        }
    }

    private var tagRows: [SidebarRow] {
        SidebarRow.rows(tree: [], tags: model.tags, expanded: [])
    }

    // MARK: - Chrome

    private func sectionHeader(_ title: String, addHelp: String, onAdd: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(addHelp)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.bottom, 2)
    }

    private func row(
        title: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        indent: CGFloat,
        entry: SidebarEntry
    ) -> some View {
        SidebarRowLabel(
            title: title,
            systemImage: systemImage,
            count: count,
            isSelected: isSelected,
            isHovered: false,
            tagColor: nil,
            zone: nil
        )
        .frame(height: rowHeight)
        .padding(.leading, indent + 16)
        .onTapGesture { model.select(entry) }
    }

    // MARK: - Naming

    private func commit(_ request: NamingRequest, name: String) {
        switch request.kind {
        case .newCollection(let parentID):
            _ = model.createCollection(name: name, parentID: parentID)
        case .renameCollection(let id):
            model.renameCollection(id, name: name)
        case .newTag:
            model.createTag(name: name)
        case .renameTag(let id):
            model.renameTag(id, name: name)
        }
    }
}

// MARK: - Drag modifier

/// Applies `.onDrag` only when there is something to drag (pinned rows must not drag).
private struct CollectionDragModifier: ViewModifier {
    let payload: String?

    func body(content: Content) -> some View {
        if let payload {
            content.onDrag { NSItemProvider(object: payload as NSString) }
        } else {
            content
        }
    }
}

// MARK: - Row label

/// The visual body of a sidebar row: icon, title, count badge, selection and drop chrome.
struct SidebarRowLabel: View {
    /// Row radius and selection wash are tokens (P1-D); the defaults reproduce P1-B.
    @Environment(\.appearance) private var tokens

    let title: String
    let systemImage: String
    let count: Int
    let isSelected: Bool
    let isHovered: Bool
    let tagColor: Color?
    let zone: SidebarDropZone?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: tokens.innerRadius))
        .overlay(alignment: .top) {
            if zone == .before {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if zone == .after {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .overlay {
            if zone == .onto {
                RoundedRectangle(cornerRadius: tokens.innerRadius).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(tokens.selectionOpacity) }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
    }
}

// MARK: - Naming sheet

struct NamingRequest: Identifiable {
    enum Kind: Equatable {
        case newCollection(parentID: UUID?)
        case renameCollection(UUID)
        case newTag
        case renameTag(UUID)
    }

    let id = UUID()
    let kind: Kind
    let initial: String

    var title: String {
        switch kind {
        case .newCollection: return "New Folder"
        case .renameCollection: return "Rename Folder"
        case .newTag: return "New Tag"
        case .renameTag: return "Rename Tag"
        }
    }
}

/// Minimal single-field prompt. A sheet beats an alert here: it is one text field, one
/// default button, and Escape cancels without any extra plumbing.
struct NameEntrySheet: View {
    let request: NamingRequest
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(request: NamingRequest, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: request.initial)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { if !trimmed.isEmpty { onSubmit(trimmed) } }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("OK") { onSubmit(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(18)
    }
}
