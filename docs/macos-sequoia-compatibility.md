# macOS Sequoia support

VoryMac targets macOS 15 while retaining the native macOS 26-or-later API
paths behind availability checks.

## What changed

- The Mac app, extensions, tests, and VoryCore target macOS 15.
- Liquid Glass uses material and standard-control fallbacks on macOS 15.
- Foundation Models and the newer Speech APIs require macOS 26 or later.
- On Sequoia, use gateway speech instead of device transcription. On-device
  Vory Summaries are unavailable.
- Debug builds missing the Keychain entitlement can keep sign-in in memory,
  with a temporary-sign-in notice. Release Keychain behavior is unchanged.
- Demo concurrency expressions and large SwiftUI view expressions were
  adjusted to compile with Xcode 26.3.

## Validation on October 31, 2026

The executable code at commit `44dc212` was checked on both hosts:

| Host OS | Xcode | Clean Debug build | VoryMac unit scheme |
| --- | --- | --- | --- |
| macOS 15.8.2 | 26.3 | Passed | 875 passed, 5 skipped, 0 failed; 156 suites |
| macOS 27.2 | 27.1 | Passed | 875 passed, 5 skipped, 0 failed; 156 suites |

- Isolated ad-hoc apps launched; visible onboarding, navigation, and demo
  message/reply flows were exercised on both hosts.
- The tester configured a real Hermes gateway and confirmed completed replies
  on both Macs. This is manual integration evidence.
- The five automated gateway E2E tests were skipped because their separate
  test environment was not configured; they are not counted as passed.
- The app reports macOS 15.0 as its minimum system version.

The Sequoia test host initially stalled before running any tests. Regenerating
its test products with the current Xcode installation path produced a complete
passing run. The cause of the earlier loader stall was not established.

## Remaining coverage

macOS 26 Tahoe has not been tested in this validation round. These ad-hoc
builds do not validate provisioned Keychain access or persistence, iCloud,
widgets, APNs, or notifications. Those require a signed build, such as
TestFlight. Debug memory fallback credentials are lost when the app quits.
iOS and watchOS builds were not rerun in this validation round.
