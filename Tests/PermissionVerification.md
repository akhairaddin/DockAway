# Permission verification

## Automated checks

Run from the repository root. These test binaries do not launch DockAway or access real privacy permissions.

```sh
swiftc -module-cache-path /private/tmp/DockAway-PermissionProbe-ModuleCache DockAway/Permissions.swift Tests/PermissionProbeStateTests.swift -o /private/tmp/DockAway-PermissionProbeStateTests
/private/tmp/DockAway-PermissionProbeStateTests
swiftc -module-cache-path /private/tmp/DockAway-PermissionProbe-ModuleCache DockAway/Permissions.swift Tests/PermissionMonitorTests.swift -o /private/tmp/DockAway-PermissionMonitorTests
/private/tmp/DockAway-PermissionMonitorTests
swiftc -module-cache-path /private/tmp/DockAway-PermissionProbe-ModuleCache DockAway/Permissions.swift Tests/RuntimePermissionAccessTests.swift -o /private/tmp/DockAway-RuntimePermissionAccessTests
/private/tmp/DockAway-RuntimePermissionAccessTests
swiftc -module-cache-path /private/tmp/DockAway-PermissionProbe-ModuleCache DockAway/Permissions.swift Tests/PermissionCompletionDecisionTests.swift -o /private/tmp/DockAway-PermissionCompletionDecisionTests
/private/tmp/DockAway-PermissionCompletionDecisionTests
```

The tests cover grant/revoke results, unexpected exits and signals, launch failure, deadlines, stale results, cancellation, and confirmation checks that cannot be superseded by ordinary refreshes. Runtime tests inject fake access reads, verify explicit resampling after regrant, and prove that canceled or timed-out workers never overlap. The completion matrix checks all 25 combinations of authorization and runtime results.

## Signed-app acceptance check

Use the same signed application at a stable path throughout this check. An unsigned command-line test cannot establish how macOS attributes permission checks to the distributed app. Perform these steps manually or in a disposable macOS test account. Do not reset the user's privacy database.

1. Start onboarding with neither permission granted. Accessibility is the first available step; Continue is disabled.
2. Open System Settings independently of DockAway. Toggle Accessibility on and off with onboarding still visible. Its circle must follow the latest reported authorization in both directions.
3. Grant Accessibility. If Input Access becomes Available automatically, do not add an unnecessary Input Monitoring entry. On systems where a separate entry is needed and present, toggle it on, off, and back on. Choose Later when macOS offers to quit. The second circle must not remain green after a confirmed authorization denial.
4. With both circles green, revoke either permission and immediately click Continue. Continue must revalidate before accepting setup. Also try clicking repeatedly and switching focus during the check.
5. Restore access and note DockAway's PID in Activity Monitor before pressing Continue. When local access checks and monitoring initialization succeed, onboarding must close, the started popover must appear, and the PID must stay unchanged. Confirm Dock hiding and four-finger pre-hide. No trackpad or an unavailable private gesture framework should retain existing degraded-mode handling, not cause a permission-restart loop.
6. Test fallback on a system where authorization is granted but the running process cannot acquire access. Continue must restart once for that attempt, producing a new PID. If either authorization check fails, onboarding must remain open with no restart. Do not force this by editing the user's TCC database.
7. Revoke access while monitoring. Monitoring must stop. Restore it, press Resume, and finish setup. Verify the in-place path when access is usable, and the restart fallback otherwise. Also revoke during Continue's local check: the final authorization check must keep onboarding open.
8. Repeat with the status menu open, then across sleep and wake. Sleep during Continue must cancel that attempt; a late result must not complete a newer attempt. A quick Pause click while the menu refreshes must still pause the app.
9. Quit during a check. No child or late callback should reopen setup or change state afterward.

Onboarding requests checks at roughly 0.4-second intervals, with only one child in flight. Normal background checks run less often. Each child has a 2-second deadline. macOS authorization propagation adds latency, so these are polling targets, not an instantaneous-delivery guarantee.

The probes use public AX and IOHID authorization APIs, not private notifications or TCC database reads. AX trust is corroborated with the posting preflight because [Chromium observed stale AX grants after revocation](https://chromium.googlesource.com/chromium/src/+/7474294381a3b199f2ecc66ed892c1e48ee1f970). These APIs report authorization, not an independently readable copy of each System Settings toggle. A toggle change that does not alter the public authorization result cannot be distinguished by this implementation.
