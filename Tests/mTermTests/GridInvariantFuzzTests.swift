import XCTest
@testable import mTerm

private func paneFrames(for grid: PaneGrid, size: CGSize) -> [UUID: CGRect] {
    var result: [UUID: CGRect] = [:]
    var x: CGFloat = 0
    for column in grid.columns {
        let w = column.widthFraction * size.width
        if column.panes.count == 1 {
            result[column.panes[0]] = CGRect(x: x, y: 0, width: w, height: size.height)
        } else if column.panes.count == 2 {
            let topH = column.rowFraction * size.height
            result[column.panes[0]] = CGRect(x: x, y: 0, width: w, height: topH)
            result[column.panes[1]] = CGRect(x: x, y: topH, width: w, height: size.height - topH)
        }
        x += w
    }
    return result
}

@MainActor
final class GridInvariantFuzzTests: XCTestCase {
    private func checkInvariants(_ store: WorkspaceStore, _ context: String) {
        // 1. No column holds more than 2 panes.
        for col in store.grid.columns {
            XCTAssertLessThanOrEqual(col.panes.count, 2, "\(context): column >2 panes \(col.panes)")
            XCTAssertGreaterThan(col.panes.count, 0, "\(context): empty column present")
        }
        // 2. At most maxColumns columns.
        XCTAssertLessThanOrEqual(store.grid.columns.count, PaneGrid.maxColumns, "\(context): too many columns")
        // 3. Every grid pane exists in sessions.
        let sessionIDs = Set(store.sessions.map(\.id))
        for id in store.grid.paneIDs {
            XCTAssertTrue(sessionIDs.contains(id), "\(context): grid pane \(id) not in sessions")
        }
        // 4. Widths sum to ~1 when non-empty.
        if !store.grid.columns.isEmpty {
            let sum = store.grid.columns.reduce(0) { $0 + $1.widthFraction }
            XCTAssertEqual(sum, 1, accuracy: 0.001, "\(context): widths sum \(sum) != 1")
        }
        // 4b. No pane id appears in more than one place in the grid.
        let ids = store.grid.paneIDs
        XCTAssertEqual(ids.count, Set(ids).count, "\(context): duplicate pane id in grid \(ids)")
        // 5. Every grid pane gets a frame.
        let frames = paneFrames(for: store.grid, size: CGSize(width: 1500, height: 900))
        for id in store.grid.paneIDs {
            XCTAssertNotNil(frames[id], "\(context): pane \(id) missing frame")
        }
    }

    func testRandomizedOperationsKeepInvariants() {
        var rng = SystemRandomNumberGenerator()
        for iteration in 0..<400 {
            let store = WorkspaceStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            var steps: [String] = []
            for _ in 0..<20 {
                let paneIDs = store.grid.paneIDs
                let allSessions = store.sessions.map(\.id)
                let op = Int.random(in: 0..<6, using: &rng)
                switch op {
                case 0:
                    store.createSession()
                    steps.append("create")
                case 1 where !paneIDs.isEmpty:
                    let target = paneIDs.randomElement(using: &rng)!
                    let dragged = allSessions.randomElement(using: &rng)!
                    let zones: [DropZone] = [.center, .left, .right, .top, .bottom]
                    let zone = zones.randomElement(using: &rng)!
                    store.place(dragged, onPaneWith: target, zone: zone)
                    steps.append("place \(zone)")
                case 2 where !paneIDs.isEmpty:
                    store.hoveredSessionID = paneIDs.randomElement(using: &rng)
                    let bg = allSessions.randomElement(using: &rng)!
                    store.openInActivePane(bg)
                    steps.append("openInActive")
                case 3 where !paneIDs.isEmpty:
                    store.openSingle(paneIDs.randomElement(using: &rng)!)
                    steps.append("openSingle")
                case 4 where store.sessions.count > 1:
                    let victim = store.sessions.randomElement(using: &rng)!
                    store.close(victim)
                    steps.append("close")
                default:
                    store.createSession()
                    steps.append("create*")
                }
                checkInvariants(store, "iter \(iteration) after [\(steps.joined(separator: ", "))]")
            }
        }
    }
}
