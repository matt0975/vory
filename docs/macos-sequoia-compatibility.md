# macOS Sequoia support

This branch keeps VoryMac running on macOS 15. Liquid Glass falls back to
regular materials and controls on Sequoia, while Foundation Models and the
newer Speech APIs stay available on macOS 26 and later.

Debug builds without the Keychain entitlement can use a temporary sign-in
instead of failing. Release behavior is unchanged. Xcode 26.3 also needed a few
SwiftUI expressions split up and a separate Swift 6.2 transcript-binding path.

## Testing

I rebased this onto `release-1.5.1` at `5e1d61a`. Clean Debug builds and the
full VoryMac test suite passed on my Mac mini running macOS 15.8.2 with Xcode
26.3, and my MacBook Air running macOS 27.3 with Xcode 27.1. Each machine
finished 1,137 tests with five skipped and no failures across 188 suites.

Both builds opened, connected and finished a reply.

## Not tested

I haven't checked Tahoe because the MacBook is on macOS 27.3. Keychain, iCloud,
widgets and push notifications still need a signed build. I didn't rerun iOS
or watchOS for this update.
