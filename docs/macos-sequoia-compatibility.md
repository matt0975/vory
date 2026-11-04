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

## Validation on November 3–4, 2026

The branch was rebased onto `release-1.5.1` at `373bc0c`. Application code
at `d8b8cf5` and the test portability fixes at `51e53c8` were checked:

| Host OS | Xcode | Clean Debug build | VoryMac unit scheme |
| --- | --- | --- | --- |
| macOS 15.8.2 | 26.3 | Passed | 1,039 passed, 5 skipped, 0 failed; 174 suites |
| macOS 27.2 | 27.1 | Passed | 1,039 passed, 5 skipped, 0 failed; 174 suites |

- The isolated Sequoia app passed visible onboarding, Home, Chats, Bots and
  Settings navigation, and a completed demo message/reply flow.
- The MacBook has since moved to macOS 27.3. Its new isolated app launched;
  local visible Chats, Home, Bots and Settings navigation and a completed demo
  reply passed there. The completed build and tests above ran on macOS 27.2.
- The five automated gateway E2E tests were skipped because their separate
  test environment was not configured; they are not counted as passed.
- The app reports macOS 15.0 as its minimum system version.
- Both clean builds retained compiler warnings. The MacBook test bundle also
  reports view-update publication and voice-player priority inversion warnings.

The updated suite needed a smaller bot-photo count expression for Xcode 26.3
and a portable math snapshot directory instead of a developer's home path.

The Sequoia test host initially stalled before running any tests. Regenerating
its test products with the current Xcode installation and running the generated
manifest with `test-without-building` produced a complete passing run. The cause
of the intermittent startup stall was not established.

The tester confirmed real Hermes replies on both Macs on October 31 using
`44dc212`. That earlier manual result does not establish real-gateway behavior
for this new rebase; the current runtime check uses the in-process demo.

## Remaining coverage

The available MacBook is on macOS 27, so Tahoe has not been checked. These ad-hoc
builds do not validate provisioned Keychain access or persistence, iCloud,
widgets, APNs, or notifications. Those require a signed build, such as
TestFlight. Debug memory fallback credentials are lost when the app quits.
iOS and watchOS builds were not rerun in this validation round.
