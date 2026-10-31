import XCTest
@testable import TrailMind

final class LibrarySelectionTests: XCTestCase {
    func testSelectsSomeAllAndCancels() {
        let selection = LibrarySelection()
        selection.toggle(1)
        XCTAssertEqual(selection.ids, [])
        selection.begin()
        selection.toggle(1)
        selection.toggle(2)
        selection.toggle(1)
        XCTAssertEqual(selection.ids, [2])
        selection.selectAll([1, 2, 3])
        XCTAssertEqual(selection.ids, [1, 2, 3])
        selection.reconcile([2, 3])
        XCTAssertEqual(selection.ids, [2, 3])
        selection.cancel()
        XCTAssertFalse(selection.enabled)
        XCTAssertEqual(selection.ids, [])
    }
}
