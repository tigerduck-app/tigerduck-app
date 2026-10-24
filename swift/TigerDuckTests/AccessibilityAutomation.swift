#if os(iOS)
import Foundation
import Testing
import UIKit

/// SwiftUI builds its accessibility tree only for a client such as VoiceOver or UI testing, and a
/// simulator without one, as in CI, leaves the elements out. This turns it on as UI testing does,
/// and off once the last suite that asked for it is done, since suites run in parallel.
@MainActor
func withAccessibilityAutomation<T>(_ body: () async throws -> T) async throws -> T {
    if AccessibilityAutomation.users == 0 { try AccessibilityAutomation.set(true) }
    AccessibilityAutomation.users += 1
    defer {
        AccessibilityAutomation.users -= 1
        if AccessibilityAutomation.users == 0 { try? AccessibilityAutomation.set(false) }
    }
    return try await body()
}

@MainActor
func accessibilityElement(labeled label: String, in node: NSObject) -> NSObject? {
    if node.accessibilityLabel == label { return node }
    for child in accessibilityChildren(of: node) {
        if let found = accessibilityElement(labeled: label, in: child) { return found }
    }
    return nil
}

@MainActor
func exposedAccessibilityLabels(in node: NSObject) -> [String] {
    let own = node.isAccessibilityElement ? [node.accessibilityLabel ?? ""] : []
    return own + accessibilityChildren(of: node).flatMap { exposedAccessibilityLabels(in: $0) }
}

@MainActor
func exposedAccessibilityTexts(in node: NSObject) -> [String] {
    let read = [node.accessibilityLabel, node.accessibilityValue].compactMap { $0 }.filter { !$0.isEmpty }
    let own = node.isAccessibilityElement ? [read.joined(separator: ", ")] : []
    return own + accessibilityChildren(of: node).flatMap { exposedAccessibilityTexts(in: $0) }
}

@MainActor
func exposedAccessibilityElements(in node: NSObject) -> [NSObject] {
    (node.isAccessibilityElement ? [node] : []) + accessibilityChildren(of: node).flatMap { exposedAccessibilityElements(in: $0) }
}

@MainActor
private func accessibilityChildren(of node: NSObject) -> [NSObject] {
    var children = node.accessibilityElements ?? []
    let count = node.accessibilityElementCount()
    if children.isEmpty, count != NSNotFound, count > 0 {
        children = (0..<count).compactMap { node.accessibilityElement(at: $0) }
    }
    if let view = node as? UIView { children += view.subviews }
    return children.compactMap { $0 as? NSObject }
}

@MainActor
private enum AccessibilityAutomation {
    static var users = 0

    static func set(_ on: Bool) throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let library = try #require(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW))
        let symbol = try #require(dlsym(library, "_AXSSetAutomationEnabled"))
        typealias SetEnabled = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(on)
    }
}
#endif
