import CoreGraphics

/// How wide the file list's columns are for the room there is (#123). Each column has a
/// preferred width (as the user dragged it, or its default) and a fitted width (just enough for
/// what it shows in the current font). With room to spare, every column has its preferred width —
/// a fitted one at least its fitted width — and Name the rest. Short of room, it is taken in this order:
/// 1. the other columns' slack, preferred → fitted (in proportion to their slack);
/// 2. Name, down to `nameMinimum` (a readable name);
/// 3. the text columns (Kind), down to their minimum;
/// 4. Name, down to its minimum;
/// 5. the fitted columns, down to their minimum (in proportion).
/// Beyond that the columns are wider than the room, and the list scrolls sideways.
enum ColumnLayout {
    enum Role: Equatable {
        /// Takes the room left over; shrinks second and fourth.
        case name
        /// Free text that can be cut (Kind): no slack to give first, shrinks third.
        case text
        /// Shows something of a known width (sizes, dates): slack first, its own width last.
        case fitted
    }

    struct Column: Equatable {
        let id: String
        let role: Role
        let preferred: CGFloat
        /// For `.fitted`: what its content needs. Ignored for the others.
        let fitted: CGFloat
        let minimum: CGFloat
    }

    static let nameMinimum: CGFloat = 160

    static func widths(_ columns: [Column], available: CGFloat) -> [String: CGFloat] {
        // A fitted column is at least as wide as its content while there is room (a long date
        // pattern), whatever its preferred width.
        var widths = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.id, max(column.preferred, column.minimum, column.role == .fitted ? column.fitted : 0))
        })
        var deficit = widths.values.reduce(0, +) - available
        if deficit <= 0 {
            if let name = columns.first(where: { $0.role == .name }) {
                widths[name.id, default: 0] -= deficit // the rest goes to the names
            }
            return widths
        }
        func shrink(_ ids: [String], to floor: (Column) -> CGFloat) {
            let candidates = columns.filter { ids.contains($0.id) }
            let room = candidates.map { max(0, (widths[$0.id] ?? 0) - floor($0)) }
            let total = room.reduce(0, +)
            guard deficit > 0, total > 0 else {
                return
            }
            let taken = min(deficit, total)
            for (column, slack) in zip(candidates, room) where slack > 0 {
                widths[column.id, default: 0] -= taken * slack / total
            }
            deficit -= taken
        }
        let fitted = columns.filter { $0.role == .fitted }.map(\.id)
        let text = columns.filter { $0.role == .text }.map(\.id)
        let name = columns.filter { $0.role == .name }.map(\.id)
        shrink(fitted) { max($0.fitted, $0.minimum) } // 1. slack
        shrink(name) { max(nameMinimum, $0.minimum) } // 2. a readable name
        shrink(text) { $0.minimum } // 3. Kind
        shrink(name) { $0.minimum } // 4. the name
        shrink(fitted) { $0.minimum } // 5. what fits no more
        return widths
    }
}
