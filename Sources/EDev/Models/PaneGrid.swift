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

    mutating func place(_ dragged: UUID, onPaneWith target: UUID, zone: DropZone) {
        guard location(of: target) != nil else { return }
        if dragged == target, zone == .center { return }
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
    }

    mutating func remove(_ id: UUID) {
        guard let loc = location(of: id) else { return }
        columns[loc.column].panes.remove(at: loc.row)
        if columns[loc.column].panes.isEmpty {
            columns.remove(at: loc.column)
            normalizeWidths()
        }
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
}
