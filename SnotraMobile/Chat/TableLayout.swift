import SwiftUI

/// A table's cells, row by row, in columns that share the available width.
///
/// Each column starts at its natural width. A table wider than `availableWidth`
/// wraps its widest columns first, down to `minimumColumnWidth`; one that still
/// does not fit falls back to columns of at most `maximumColumnWidth` and is left
/// to scroll sideways. A row is as tall as its tallest wrapped cell.
struct TableLayout: Layout {
    let columns: Int
    /// The width the table should fit into; `nil` until it is known.
    let availableWidth: CGFloat?
    var minimumColumnWidth: CGFloat = 96
    var maximumColumnWidth: CGFloat = 240

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (widths, heights) = measure(subviews)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (widths, heights) = measure(subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for (column, width) in widths.enumerated() {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
                x += width
            }
            y += height
        }
    }

    private func measure(_ subviews: Subviews) -> (widths: [CGFloat], heights: [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        var natural = Array(repeating: CGFloat(0), count: columns)
        for (index, subview) in subviews.enumerated() {
            natural[index % columns] = max(natural[index % columns], subview.sizeThatFits(.unspecified).width)
        }
        let widths = Self.columnWidths(natural: natural, minimum: minimumColumnWidth,
                                       maximum: maximumColumnWidth, available: availableWidth)
        let rows = (subviews.count + columns - 1) / columns
        let heights = (0..<rows).map { row in
            (0..<columns).reduce(CGFloat(0)) { tallest, column in
                let index = row * columns + column
                guard index < subviews.count else { return tallest }
                let proposal = ProposedViewSize(width: widths[column], height: nil)
                return max(tallest, subviews[index].sizeThatFits(proposal).height)
            }
        }
        return (widths, heights)
    }

    /// The columns' widths for their natural widths: unchanged when they fit, the widest ones
    /// lowered to a common cap (never below `minimum`) when they don't, and each capped at
    /// `maximum` for sideways scrolling when even that is too wide or `available` is unknown.
    static func columnWidths(natural: [CGFloat], minimum: CGFloat, maximum: CGFloat, available: CGFloat?) -> [CGFloat] {
        guard let available else { return natural.map { min($0, maximum) } }
        if natural.reduce(0, +) <= available { return natural }
        let floors = natural.map { min($0, minimum) }
        if floors.reduce(0, +) >= available { return natural.map { min($0, maximum) } }
        func widths(_ cap: CGFloat) -> [CGFloat] { zip(natural, floors).map { max($1, min($0, cap)) } }
        var low: CGFloat = 0, high = natural.max() ?? 0
        for _ in 0..<40 {
            let cap = (low + high) / 2
            if widths(cap).reduce(0, +) > available { high = cap } else { low = cap }
        }
        return widths(low)
    }
}
