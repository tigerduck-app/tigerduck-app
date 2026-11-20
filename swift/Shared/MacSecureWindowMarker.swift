import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)

struct MacSecureWindowMarker: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> MacSecureWindowMarkerView {
        MacSecureWindowMarkerView()
    }

    func updateNSView(_ nsView: MacSecureWindowMarkerView, context: Context) {
        nsView.setActive(active)
    }
}

@MainActor
final class MacSecureWindowMarkerView: NSView {
    private var active = false
    private var heldWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if active, heldWindow !== window {
            if let previous = heldWindow {
                MacSecureWindowRegistry.release(previous)
            }
            heldWindow = window
            if let window {
                MacSecureWindowRegistry.acquire(window)
            }
        }
    }

    func setActive(_ newValue: Bool) {
        guard newValue != active else { return }
        active = newValue
        if newValue {
            if let window {
                MacSecureWindowRegistry.acquire(window)
                heldWindow = window
            }
        } else if let previous = heldWindow {
            MacSecureWindowRegistry.release(previous)
            heldWindow = nil
        }
    }

    deinit {
        // The view can go away before `updateNSView` clears `active`, as when a sheet closes
        // mid-toggle. NSView deinit runs on the main thread, so `assumeIsolated` balances the
        // ref-count now; a later run-loop turn would briefly strand `sharingType = .none`.
        MainActor.assumeIsolated {
            if active, let previous = heldWindow {
                MacSecureWindowRegistry.release(previous)
            }
        }
    }
}

@MainActor
private enum MacSecureWindowRegistry {
    private final class Entry {
        var count: Int
        let preexisting: NSWindow.SharingType
        init(count: Int, preexisting: NSWindow.SharingType) {
            self.count = count
            self.preexisting = preexisting
        }
    }

    private static var holders: [ObjectIdentifier: Entry] = [:]

    static func acquire(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let entry = holders[key] {
            entry.count += 1
            return
        }
        let previous = window.sharingType
        holders[key] = Entry(count: 1, preexisting: previous)
        if previous != .none {
            window.sharingType = .none
        }
    }

    static func release(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard let entry = holders[key] else { return }
        entry.count -= 1
        guard entry.count <= 0 else { return }
        holders.removeValue(forKey: key)
        if entry.preexisting != .none {
            window.sharingType = entry.preexisting
        }
    }
}

#endif
