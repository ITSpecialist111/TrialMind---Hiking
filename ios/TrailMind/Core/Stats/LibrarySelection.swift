import Foundation

final class LibrarySelection {
    private(set) var enabled = false
    private var selected = Set<Int64>()
    var ids: Set<Int64> { selected }

    func begin() { enabled = true }

    func cancel() {
        enabled = false
        selected.removeAll()
    }

    func toggle(_ id: Int64) {
        if enabled && selected.remove(id) == nil { selected.insert(id) }
    }

    func selectAll<S: Sequence>(_ eligible: S) where S.Element == Int64 {
        if enabled { selected = Set(eligible) }
    }

    func reconcile<S: Sequence>(_ eligible: S) where S.Element == Int64 { selected.formIntersection(eligible) }
}
