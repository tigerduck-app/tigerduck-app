# 0021. Hide sensitive views from screen capture per platform

Status: accepted

## Context

Password fields and the library QR code show credentials that a screenshot, a screen recording,
AirPlay or Sidecar mirroring, or Screen Sharing would leak. Android blanks them with the
per-window `FLAG_SECURE` flag (its `SecureScreen` composable). iOS and iPadOS have no such flag,
macOS has `NSWindow.sharingType`, and watchOS has no public capture-exclusion API.

## Decision

`View.screenCaptureProtected(_:)` (`swift/Shared/ScreenCaptureProtected.swift`) is the one entry
point; `PasswordField`, `LibraryQRCodeView`, `MacLoginView` and the Watch `LibraryQRView` use it.

- iOS and iPadOS: `SecureCaptureContainer` hosts the view in a `UIHostingController` on the
  private canvas of a `UITextField` with `isSecureTextEntry` set, which the system leaves out of
  screenshots, recordings and mirroring along with its subviews. The wrap is always applied and
  `active` is ignored. The canvas is the first descendant whose class name contains "Canvas";
  without one the content goes on the wrapper itself, unprotected, and DEBUG builds assert while
  release builds still render it so the user is not locked out.
- macOS: a `.background` marker (`MacSecureWindowMarker`) sets `NSWindow.sharingType = .none`
  while active; it updates without touching the content, so `active` is honored.
  `MacSecureWindowRegistry` counts holders per window and puts back only a value it replaced, so
  nested callers do not undo each other.
- watchOS: a no-op. What is left needs the wearer's own devices: the side-button and Digital
  Crown screenshot, and Apple Watch Mirroring to the paired iPhone.
- DEBUG builds can turn it off in Settings → Developer (`ScreenCaptureProtectionDebugFlag`).

## Alternatives

- Honoring `active` on iOS by adding and removing the wrap: it changes structural identity and
  rebuilds the hosted UIKit views, dropping the keyboard mid-typing; over-protecting is harmless.
- Wrapping whole screens: the hosting controller starts a fresh SwiftUI environment and drops
  the parent's `@Environment` values. Forwarding `context.environment` did not help: the crash
  on `OnboardingView`'s login page came from SwiftUI in UIKit in SwiftUI bridging depth, notably
  under `TabView`'s lazy pages, and Apple offers no way around it.

## Consequences

- Wrap small sensitive leaves with no environment dependency, never a whole screen.
- The iOS wrapper sizes itself (`SecureCaptureHostView.fitting(_:)`, `intrinsicContentSize`) so
  Form rows do not flash tall and a QR code under `.aspectRatio(1, .fit)` keeps its size.
- If UIKit drops "Canvas" from its private class name, release builds silently lose iOS
  protection; the DEBUG assertion is the only signal.
- The Mac protection is best effort: Apple documents `NSWindow.SharingType.none` as a legacy
  value that keeps content out of only some sharing situations and says not to use it to hide
  content from capture
  (https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).
