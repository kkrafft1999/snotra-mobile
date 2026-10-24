import Foundation
import Testing
@testable import SnotraMobile

/// How a Markdown table's columns share the width of the screen (`TableLayout`).
struct TableLayoutTests {
    func widths(_ natural: [CGFloat], available: CGFloat?) -> [CGFloat] {
        TableLayout.columnWidths(natural: natural, minimum: 96, maximum: 240, available: available)
    }

    func isClose(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }

    @Test func aTableThatFitsKeepsItsNaturalWidths() {
        #expect(widths([120, 70, 300], available: 500) == [120, 70, 300])
    }

    @Test func theWidestColumnWrapsFirstAndTheRestKeepTheirWidth() {
        // The task list from the report: a long task, a short priority and a date.
        #expect(isClose(widths([420, 70, 80], available: 350), [200, 70, 80]))
    }

    @Test func twoWideColumnsShareTheWidthLeft() {
        #expect(isClose(widths([400, 300, 50], available: 350), [150, 150, 50]))
    }

    @Test func noColumnWrapsBelowTheMinimum() {
        #expect(isClose(widths([400, 300, 200], available: 291), [97, 97, 97]))
        #expect(widths([400, 300, 200], available: 280) == [240, 240, 200])
    }

    @Test func aTableTooWideEvenAtTheMinimumScrollsWithCappedColumns() {
        #expect(widths([400, 300, 200, 150], available: 350) == [240, 240, 200, 150])
    }

    @Test func anUnknownWidthCapsTheColumns() {
        #expect(widths([400, 70], available: nil) == [240, 70])
    }
}
