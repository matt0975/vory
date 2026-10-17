# macOS Sequoia support

This branch lets VoryMac run on macOS 15 while keeping the macOS 26 path in
place.

## What changed

- The Mac app, extensions, tests, and VoryCore now target macOS 15.
- Liquid Glass uses material and standard-control fallbacks on macOS 15.
- Foundation Models and the newer Speech APIs only run on macOS 26.
- On Sequoia, gateway speech still works. Device transcription does not.

## Checked

- Built and launched VoryMac on macOS 15.8.2.
- 461 tests in 94 suites passed.
- Confirmed the app reports macOS 15.0 as its minimum.
- Checked status, sign-in, and the WebSocket connection with a Hermes gateway.

## Still to check

The local build is ad-hoc signed. Shared Keychain, iCloud restore, widgets,
and notifications still need checking in a signed build.
