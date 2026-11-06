import CoreTransferable
import SwiftUI
import UIKit
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
    static func move(
        _ draggedID: String,
        onto targetID: String,
        in itemIDs: [String],
        moveAction: (IndexSet, Int) -> Void
    ) -> Bool {
        guard let (fromOffsets, destination) = moveDestination(in: itemIDs, draggedID: draggedID, targetID: targetID) else {
            return false
        }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smoothSpring) {
            moveAction(fromOffsets, destination)
        }
        return true
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
              ReorderDropSupport.move(payload.id, onto: targetID, in: currentIDs(), moveAction: moveAction) else {
            return
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

extension View {
    func reorderAccessibilityActions(
        _ id: String,
        shown shownIDs: [String],
        currentIDs: @escaping () -> [String],
        moveAction: @escaping (IndexSet, Int) -> Void,
        onPersist: @escaping () -> Void
    ) -> some View {
        let index = shownIDs.firstIndex(of: id)
        func step(_ offset: Int) {
            guard let index, shownIDs.indices.contains(index + offset),
                  ReorderDropSupport.move(id, onto: shownIDs[index + offset], in: currentIDs(), moveAction: moveAction)
            else { return }
            onPersist()
            var position = AttributedString(
                String(format: String(localized: "a11y_home_edit_position"), index + offset + 1, shownIDs.count)
            )
            // Other speech cannot interrupt a high-priority announcement (AccessibilityNotification.Announcement).
            position.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(position).post()
        }
        // SwiftUI hands VoiceOver these actions last first, so move up comes first in the Actions rotor.
        return accessibilityActions {
            if let index, index < shownIDs.count - 1 {
                Button(String(localized: "a11y_home_edit_move_down")) { step(1) }
            }
            if let index, index > 0 {
                Button(String(localized: "a11y_home_edit_move_up")) { step(-1) }
            }
        }
    }
}
