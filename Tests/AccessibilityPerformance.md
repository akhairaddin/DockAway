# Accessibility responsiveness review

## Checkpoint and baseline

Before edits, the complete source state was saved in local commit `ab4331f`.
A separate archive includes the whole working directory, including Git metadata
and ignored files:
`/private/tmp/DockAway-before-ax-smoothness.eHRv5R/DockAway-complete-checkpoint.tar.gz`.
The archive is temporary; the local Git commit is the durable source checkpoint.

On September 6, 2026, a 12-second, 1 ms sampling request inspected the existing
running Debug app (PID 46584, version 1.2/build 12, macOS 27.0).
The sample contained eight main-thread sample stacks in `missionControlAXState`,
including waits inside `AXUIElementCopyAttributeValue`. It did not establish a
long animation hitch, CPU improvement, or energy saving. Raw baseline:
`/private/tmp/DockAway-AX-before.sample.txt`.

These reads previously walked the Dock's children synchronously on the UI
thread. A 100 ms per-message timeout did not bound the whole walk. Apple's
[AX timeout documentation](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout)
describes per-element timeouts; its
[responsiveness guidance](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)
recommends keeping potentially blocking non-UI work off the main thread.

## Focused changes

- Repeated Mission Control AX reads use a dedicated serial background worker.
  One in-flight read and one replaceable follow-up prevent query backlogs.
- Stop/start, Dock replacement, and notification revisions reject stale results.
  A canceled read keeps its worker slot until the framework call actually exits.
- The hierarchy walk shares a 200 ms requested-wait budget. This is not a hard
  scheduling deadline and does not claim that the OS can forcibly cancel IPC.
- Startup decisions and gesture pre-hide wait for initial state resolution.
  Contacts beginning with an unknown state skip pre-hide until finger lift;
  they are not misclassified as Mission Control gestures.
  The existing WindowServer fallback remains; two unknown sources do not create
  a false Mission Control exit. A notification's fallback request survives
  coalescing with ordinary timer ticks.
- Blacklist menu construction skips Launch Services, bundle metadata, and file
  icon lookups for apps whose live metadata already supplies the same row.
- The 0.5-second permission health timer allows 0.05-second tolerance. Polling
  policy, permission decisions, and animation timings are unchanged.

## Automated verification

Run from the repository root:

```sh
xcrun swiftc -swift-version 5 -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors DockAway/MissionControlProbe.swift Tests/MissionControlProbeTests.swift -o /private/tmp/DockAway-MissionControlProbeTests
/private/tmp/DockAway-MissionControlProbeTests
```

The tests inject a deliberately blocked reader, check that the main queue can
still respond, and exercise coalescing, state edges, PID changes, cancellation,
and unknown results. These are deterministic concurrency checks, not a claim
that a user's animation has been measured before and after the change.

Validation passed: Debug and Release builds, the strict-concurrency probe suite,
the four existing permission suites, Dock settings checks, and all 12 Python
release tests. The build's App Intents metadata-skipped warning is unrelated to
these changes. These checks do not replace signed-app gesture acceptance tests.

## Signed-build acceptance checks before release

Keep the same signed app identity and location. Let each state settle and repeat
matched trials before comparing traces. Do not toggle the user's permissions or
change other apps merely to manufacture a benchmark.

1. Start or resume DockAway both on the desktop and inside Mission Control.
   Initial uncertainty must not toggle the Dock or change landing geometry.
2. Enter and exit Mission Control repeatedly, including a horizontal gesture
   immediately after resume. Confirm empty/occupied/blacklisted destinations.
3. Pause, resume, and quit during a pending read. Old results must not alter the
   new session. Repeat across sleep/wake and a normal Dock restart.
4. Open the status menu and drag its native sliders while other apps are busy.
   Compare a matched sample or Instruments trace with the checkpoint build.
5. Verify the blacklist still lists running and non-running ignored apps, keeps
   the current-app row separate, and updates Remove All immediately.

Remaining synchronous work includes observer registration, initial app-window
enumeration, and some WindowServer queries. Moving observer lifetimes and
registrations to another executor is a separate, higher-risk change and was
not bundled into this release-focused patch. The running app was not replaced
for this review, so end-to-end visual improvement remains to be verified.
