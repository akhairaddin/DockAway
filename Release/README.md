# DockAway release automation

`DockAway.releaseplan` is the reusable Rilmazafone release plan for DockAway.
It embeds the current DMG design and keeps credentials out of the repository.

## One-time requirements

- Rilmazafone's GitHub build is installed in `/Applications`.
- The `DockAway-Notary` notarytool keychain profile exists.
- `gh auth status` succeeds for `akhairaddin/DockAway`.
- Sparkle's `generate_appcast` tool exists in Xcode DerivedData.
- Sparkle's private EdDSA key remains in the login keychain.
- Python 3.9 or later is available for offline release metadata validation.

Run this harmless preflight whenever the signing setup changes:

```sh
/Applications/Rilmazafone.app/Contents/MacOS/Rilmazafone \
  release doctor Release/DockAway.releaseplan
```

## Publishing a release

1. Commit the DockAway source, changelog, README, and release notes you want to ship.
2. Open `Release/DockAway.releaseplan` in Rilmazafone.
3. Confirm the proposed patch version and build number.
4. Press Publish. Any notes you supply supplement the complete matching section
   of `changelog.html`, which is always included automatically.

Rilmazafone bumps the patch version and build number, archives the universal
app, signs it, notarizes and staples the app, builds the embedded DMG design,
notarizes and staples the DMG, verifies the mounted result, and archives dSYMs.

Before publishing anything, the Script stage runs Sparkle's appcast generator
and validates the release entry. Missing changelog sections fail this preflight.
It then pushes the version commit and creates the GitHub release using the
existing unprefixed tag convention, such as `1.2`.

DMG asset names contain their SHA-256 digest. Changed binaries get new URLs;
previous assets are retained so cached appcasts remain usable. Existing tags
must point at the release commit. The scripts never silently move tags or
replace existing download bytes. A mismatched tag requires an explicit decision
before retrying, usually publishing a new version.

The post-publish stage downloads the GitHub asset and verifies that its bytes
match the local archive before committing and pushing `appcast.xml`. Validation
checks version, build order, URL, size, and signature on the same item. Release
separators and the per-item changelog link are restored automatically.

Run the offline metadata tests with:

```sh
python3 -B -m unittest discover -s Tests -p '*_tests.py'
```

## Post-release development version

Every DockAway release ends by advancing Xcode to the next development version
and incrementing the build number. This happens after the released commit and
artifacts are finished, so the repository is immediately ready for work on the
next release.

DockAway uses this marketing-version sequence:

- `1.1.9` is followed by `1.2`.
- `1.2` is followed by `1.2.1`, then through `1.2.9`.
- `1.2.9` is followed by `1.3`, never `1.2.10`.

Build numbers remain simple increasing integers regardless of the marketing
version. For example, `1.1.9 (11)` is followed by `1.2 (12)`.

## Output

- DMGs: `DockAway/dist/releases/`
- dSYMs: `DockAway/dist/dSYMs/`
- Persistent Rilmazafone build record and logs: managed by Rilmazafone

Both output directories are already covered by `DockAway/.gitignore`.

## Testing permission onboarding

Quit DockAway before using either reset. To test only the native Input
Monitoring request:

```sh
Release/reset-permissions-for-testing.sh input
```

To replay the complete Accessibility followed by Input Monitoring onboarding:

```sh
Release/reset-permissions-for-testing.sh full
```

The helper resets only DockAway's macOS privacy records. It does not change
permissions for any other application.
