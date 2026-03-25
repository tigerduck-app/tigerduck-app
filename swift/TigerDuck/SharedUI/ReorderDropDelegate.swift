import SwiftUI

/// Generic drop delegate that handles drag-to-reorder for any list of Identifiable+Equatable items.
/// Replaces the per-type SectionDropDelegate, WidgetDropDelegate, and TabDropDelegate.
struct ReorderDropDelegate<T: Identifiable & Equatable>: DropDelegate {
    let targetItem: T
    @Binding var items: [T]
    @Binding var draggingItem: T?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingItem,
              dragging.id != targetItem.id,
              let fromIndex = items.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = items.firstIndex(where: { $0.id == targetItem.id }) else { return }
        withAnimation(.smoothSpring) {
            items.move(fromOffsets: IndexSet(integer: fromIndex),
                       toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        return true
    }
}
