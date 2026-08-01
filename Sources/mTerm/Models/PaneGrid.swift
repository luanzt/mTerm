import CoreGraphics
import Foundation

enum DropZone: Equatable {
    case center, left, right, top, bottom
}

struct GridColumn: Equatable {
    var panes: [UUID]
    var widthFraction: CGFloat = 1
    var rowFraction: CGFloat = 0.5
}

struct PaneGrid: Equatable {
    var columns: [GridColumn]

    static let maxColumns = 3

    static func single(_ id: UUID) -> PaneGrid {
        PaneGrid(columns: [GridColumn(panes: [id])])
    }

    var isEmpty: Bool { columns.isEmpty }

    var paneIDs: [UUID] { columns.flatMap(\.panes) }

    func location(of id: UUID) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.panes.firstIndex(of: id) { return (c, r) }
        }
        return nil
    }

    func allowedZones(forPaneWith id: UUID) -> Set<DropZone> {
        guard let loc = location(of: id) else { return [] }
        var zones: Set<DropZone> = [.center]
        if columns.count < Self.maxColumns {
            zones.insert(.left)
            zones.insert(.right)
        }
        if columns[loc.column].panes.count == 1 {
            zones.insert(.top)
            zones.insert(.bottom)
        }
        return zones
    }

    /// Valid destinations for moving a pane that is already visible. Capacity
    /// is evaluated after hypothetically removing the source, so moving the sole
    /// pane out of one of three columns can still create a column beside the
    /// target, and two rows in the same column can be reordered.
    func allowedZonesForMovingPane(
        _ dragged: UUID,
        onPaneWith target: UUID
    ) -> Set<DropZone> {
        guard dragged != target,
              location(of: dragged) != nil,
              location(of: target) != nil else { return [] }

        var remainder = self
        remainder.remove(dragged)
        guard let targetLocation = remainder.location(of: target) else { return [] }

        var zones: Set<DropZone> = [.center]
        if remainder.columns.count < Self.maxColumns {
            zones.formUnion([.left, .right])
        }
        if remainder.columns[targetLocation.column].panes.count == 1 {
            zones.formUnion([.top, .bottom])
        }
        return zones
    }

    /// Adds a brand-new pane in its own slot without displacing existing panes.
    /// Prefers a new column on the right (while under the column cap); otherwise
    /// splits the first single-pane column into two rows. Returns `false` when the
    /// grid is completely full (every column already holds two panes).
    @discardableResult
    mutating func addPane(_ id: UUID) -> Bool {
        if paneIDs.contains(id) { return true }
        if columns.count < Self.maxColumns {
            columns.append(GridColumn(panes: [id]))
            normalizeWidths()
            enforceInvariants()
            return true
        }
        if let idx = columns.firstIndex(where: { $0.panes.count == 1 }) {
            columns[idx].panes.append(id)
            enforceInvariants()
            return true
        }
        return false
    }

    mutating func place(_ dragged: UUID, onPaneWith target: UUID, zone: DropZone) {
        guard location(of: target) != nil else { return }
        if dragged == target { return }
        guard allowedZones(forPaneWith: target).contains(zone) else { return }

        remove(dragged)                                   // move semantics
        guard let loc = location(of: target) else { return }

        switch zone {
        case .center:
            columns[loc.column].panes[loc.row] = dragged
        case .left:
            columns.insert(GridColumn(panes: [dragged]), at: loc.column)
            normalizeWidths()
        case .right:
            columns.insert(GridColumn(panes: [dragged]), at: loc.column + 1)
            normalizeWidths()
        case .top:
            columns[loc.column].panes.insert(dragged, at: 0)
        case .bottom:
            columns[loc.column].panes.append(dragged)
        }
        enforceInvariants()
    }

    /// Moves a pane that is already in the grid. Center swaps the two visual
    /// slots; edge zones relocate the source without hiding the target.
    mutating func movePane(
        _ dragged: UUID,
        onPaneWith target: UUID,
        zone: DropZone
    ) {
        guard allowedZonesForMovingPane(dragged, onPaneWith: target).contains(zone),
              let sourceLocation = location(of: dragged),
              let targetLocation = location(of: target) else { return }

        if zone == .center {
            columns[sourceLocation.column].panes[sourceLocation.row] = target
            columns[targetLocation.column].panes[targetLocation.row] = dragged
            enforceInvariants()
            return
        }

        remove(dragged)
        guard let location = location(of: target) else { return }

        switch zone {
        case .center:
            break
        case .left:
            columns.insert(GridColumn(panes: [dragged]), at: location.column)
            normalizeWidths()
        case .right:
            columns.insert(GridColumn(panes: [dragged]), at: location.column + 1)
            normalizeWidths()
        case .top:
            columns[location.column].rowFraction = 0.5
            columns[location.column].panes.insert(dragged, at: 0)
        case .bottom:
            columns[location.column].rowFraction = 0.5
            columns[location.column].panes.append(dragged)
        }
        enforceInvariants()
    }

    mutating func remove(_ id: UUID) {
        if let loc = location(of: id) {
            columns[loc.column].panes.remove(at: loc.row)
        }
        enforceInvariants()
    }

    mutating func resizeColumn(pairLeadingIndex index: Int, leadingFraction fraction: CGFloat) {
        guard columns.indices.contains(index), columns.indices.contains(index + 1) else { return }
        let pairTotal = columns[index].widthFraction + columns[index + 1].widthFraction
        let clamped = min(max(fraction, 0.2), 0.8)
        columns[index].widthFraction = pairTotal * clamped
        columns[index + 1].widthFraction = pairTotal * (1 - clamped)
    }

    mutating func resizeRow(columnIndex index: Int, topFraction fraction: CGFloat) {
        guard columns.indices.contains(index) else { return }
        columns[index].rowFraction = min(max(fraction, 0.2), 0.8)
    }

    private mutating func normalizeWidths() {
        guard !columns.isEmpty else { return }
        let equal = 1 / CGFloat(columns.count)
        for i in columns.indices { columns[i].widthFraction = equal }
    }

    /// Restores the grid's invariants after a mutation: no pane id may appear in
    /// more than one place (a UI drag race can momentarily duplicate one, which
    /// would blank the earlier column when frames are laid out), and no column
    /// may be empty. The first occurrence of a duplicate id wins so a pane keeps
    /// its original slot rather than jumping.
    private mutating func enforceInvariants() {
        var seen = Set<UUID>()
        for c in columns.indices {
            columns[c].panes.removeAll { id in
                if seen.contains(id) { return true }
                seen.insert(id)
                return false
            }
        }
        let countBefore = columns.count
        columns.removeAll { $0.panes.isEmpty }
        if columns.count != countBefore {
            normalizeWidths()
        }
    }
}
