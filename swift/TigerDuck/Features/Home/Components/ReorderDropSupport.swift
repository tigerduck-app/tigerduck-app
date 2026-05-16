import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let tigerDuckReorderPayload = UTType.json
}

struct ReorderDragPayload: Codable, Hashable, Identifiable, Sendable, Transferable {
    enum Kind: String, Codable, Hashable, Sendable {
        case homeSection
        case widget
    }

    let id: String
    let kind: Kind
    let containerID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tigerDuckReorderPayload)
    }
}

enum ReorderDropSupport {
    static func moveDestination(
        in itemIDs: [String],
        draggedID: String,
        targetID: String
    ) -> (IndexSet, Int)? {
        guard let fromIndex = itemIDs.firstIndex(of: draggedID),
              let toIndex = itemIDs.firstIndex(of: targetID),
              fromIndex != toIndex else {
            return nil
        }

        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        return (IndexSet(integer: fromIndex), destination)
    }

    @discardableResult
    static func finalizeDrop(
        activePayload: Binding<ReorderDragPayload?>,
        didReorder: Binding<Bool>,
        onPersist: () -> Void
    ) -> Bool {
        guard activePayload.wrappedValue != nil else { return false }

        let reordered = didReorder.wrappedValue
        activePayload.wrappedValue = nil
        didReorder.wrappedValue = false

        if reordered {
            onPersist()
        }

        return reordered
    }
}

struct ReorderDropDelegate: DropDelegate {
    let targetID: String
    let expectedKind: ReorderDragPayload.Kind
    let containerID: String
    @Binding var activePayload: ReorderDragPayload?
    @Binding var didReorder: Bool
    let currentIDs: () -> [String]
    let moveAction: (IndexSet, Int) -> Void
    let onPersist: () -> Void

    func dropEntered(info: DropInfo) {
        guard let payload = validatedPayload(info: info),
              let (fromOffsets, destination) = ReorderDropSupport.moveDestination(
                  in: currentIDs(),
                  draggedID: payload.id,
                  targetID: targetID
              ) else {
            return
        }

        withAnimation(.smoothSpring) {
            moveAction(fromOffsets, destination)
        }
        didReorder = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validatedPayload(info: info) != nil else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        ReorderDropSupport.finalizeDrop(
            activePayload: $activePayload,
            didReorder: $didReorder,
            onPersist: onPersist
        )
    }

    private func validatedPayload(info: DropInfo) -> ReorderDragPayload? {
        guard info.hasItemsConforming(to: [.tigerDuckReorderPayload]),
              let activePayload,
              activePayload.kind == expectedKind,
              activePayload.containerID == containerID else {
            return nil
        }

        return activePayload
    }
}

struct ReorderContainerDropDelegate: DropDelegate {
    let expectedKind: ReorderDragPayload.Kind
    let containerID: String
    @Binding var activePayload: ReorderDragPayload?
    @Binding var didReorder: Bool
    let onPersist: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validatedPayload(info: info) != nil else { return nil }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validatedPayload(info: info) != nil else { return false }

        return ReorderDropSupport.finalizeDrop(
            activePayload: $activePayload,
            didReorder: $didReorder,
            onPersist: onPersist
        )
    }

    private func validatedPayload(info: DropInfo) -> ReorderDragPayload? {
        guard info.hasItemsConforming(to: [.tigerDuckReorderPayload]),
              let activePayload,
              activePayload.kind == expectedKind,
              activePayload.containerID == containerID else {
            return nil
        }

        return activePayload
    }
}
