# 0009. Light the library QR with EDR, pinning brightness only as a fallback

Status: accepted

## Context

The library QR code (`LibraryView`, `LibraryQRCodeView`) has to read at a scanner. Pinning
system brightness at 1.0, as Wallet does, works on any display, but it overrides a global
setting and the app must give each panel its brightness back. On an EDR display a Metal layer
can light the code's white cells above SDR white without touching system brightness.

## Decision

- `HDRQRCodeImage` (`swift/TigerDuck/Features/Library/Components/HDRQRCodeImage.swift`) draws
  the QR into a `CAMetalLayer` with `wantsExtendedDynamicRangeContent`, and its shader multiplies
  the white cells by `brightness` (5.0). `LibraryQRRenderer` stays a plain SDR CoreImage render.
- An SDR `Image` sits under the Metal view, which stays transparent until the shared
  `EDRMetalStack` is built, and for good without a Metal device or when the shader does not
  compile, so the code always shows.
- `LibraryView.edrIsAvailable` picks the path: `HDRQRCodeImage.isSupported` and
  `potentialEDRHeadroom > 1.0`. Apple documents `potentialEDRHeadroom` as queryable even when
  the screen shows no EDR content, and as the ratio of the screen's brightest white to SDR white
  it is 1.0 on SDR panels.
- Without EDR, `LibraryBrightnessCoordinator` pins the panel at 1.0 and counts claims per panel.
  Several `LibraryView`s can be alive at once (the Library tab and the copies Home and More
  push), and with per-view state the second would save the boosted 1.0 as its pre-boost value,
  leaving no way to restore the panel. Per-panel claims keep windows on two displays from
  evicting each other. A window that moves displays, as on a fold, boosts the new one and
  restores the old one, and a view that does not boost holds no claim.

## Alternatives

- Always pinning system brightness, as Wallet does: it overrides a global setting on displays
  that do not need it.
- An HDR CoreImage render shown with `Image(...).allowedDynamicRange(.high)`: CoreImage clamps
  to `0...1` in non-extended working spaces, SwiftUI does not reliably tag a synthetic `UIImage`
  as HDR, and Apple's SwiftUI EDR sample draws through a Metal layer
  (https://developer.apple.com/videos/play/wwdc2022/10114/).
- Deciding from `currentEDRHeadroom`: it changes with whether EDR content is on screen, so at
  `onAppear`, before the Metal layer has drawn, it reads 1.0 on every device and would pin EDR
  iPhones at full brightness too.

## Consequences

- A thermally throttled EDR display reports potential headroom above 1 while delivering less,
  so the QR shows at ordinary SDR white instead of boosted, which still scans.
- `LibraryBrightnessCoordinatorTests` pins the claim counting.
