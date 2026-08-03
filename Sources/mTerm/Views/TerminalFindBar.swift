import AppKit
import SwiftTerm
import SwiftUI

/// Direction of a find step. A plain Return searches forward; Shift+Return
/// searches backward.
enum FindDirection: Equatable {
    case next
    case previous

    static func fromReturn(modifierFlags: NSEvent.ModifierFlags) -> FindDirection {
        modifierFlags.contains(.shift) ? .previous : .next
    }
}

/// Formats the match counter shown beside the find field.
enum FindMatchCounter {
    /// `nil` hides the label (empty term). `"No results"` when nothing matched.
    /// Otherwise `"index / total"`, where `index` is the 1-based current match.
    static func text(term: String, index: Int, total: Int) -> String? {
        guard !term.isEmpty else { return nil }
        guard total > 0 else { return "No results" }
        return "\(index) / \(total)"
    }
}
