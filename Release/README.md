# DockAway release automation

`DockAway.releaseplan` is the reusable Rilmazafone release plan for DockAway.
It embeds the current DMG design and keeps credentials out of the repository.

## One-time requirements

- Rilmazafone's GitHub build is installed in `/Applications`.
- The `DockAway-Notary` notarytool keychain profile exists.
- `gh auth status` succeeds for `akhairaddin/DockAway`.
- Sparkle's `generate_appcast` tool exists in Xcode DerivedData.
- Sparkle's private EdDSA key remains in the login keychain.

Run this harmless preflight whenever the signing setup changes:

```sh
/Applications/Rilmazafone.app/Contents/MacOS/Rilmazafone \
  release doctor Release/DockAway.releaseplan
```

## Publishing a release

1. Commit the DockAway source, changelog, README, and release notes you want to ship.
2. Open `Release/DockAway.releaseplan` in Rilmazafone.
3. Confirm the proposed patch version and build number.
4. Press Publish and provide the GitHub release notes when prompted.

Rilmazafone bumps the patch version and build number, archives the universal
app, signs it, notarizes and staples the app, builds the embedded DMG design,
notarizes and staples the DMG, verifies the mounted result, and archives dSYMs.

The Script publish stage then pushes the version commit and creates the GitHub
release using DockAway's existing unprefixed tag convention, such as `1.1.10`.
The post-publish stage runs Sparkle's official appcast generator, commits
`appcast.xml`, and pushes the update feed only after the DMG is on GitHub.

If no release notes are supplied, GitHub generates them automatically.

## Output

- DMGs: `DockAway/dist/releases/`
- dSYMs: `DockAway/dist/dSYMs/`
- Persistent Rilmazafone build record and logs: managed by Rilmazafone

Both output directories are already covered by `DockAway/.gitignore`.
