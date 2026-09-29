# DockAway Workspace Rules

## Release Workflow

Before preparing, validating, or publishing any DockAway release, read `Release/README.md` completely and follow its workflow. Treat the `Release/` directory as local-only release infrastructure and do not add it to Git or publish it to GitHub.

## Changelogs and GitHub Release Notes Policy

For DockAway changelogs (`changelog.html`) and GitHub release notes, always describe changes relative to the most recent publicly released version.

### Required Categories
Use exactly these three categories in this order:
1. **New Features**
2. **Improvements**
3. **Bug Fixes**

### Classification Rules
- **New Features**: New user-visible capabilities introduced in this release. Describe the final polished behavior, not the development process.
- **Improvements**: Meaningful improvements to features that already existed in the previous public release.
- **Bug Fixes**: Bugs that users could experience in the previous public release and that this release fixes.

### Important Rules
- **Order by relevance and impact**: Whenever adding to or editing a changelog or release notes, re-evaluate the order of all entries within each category of the affected release. Put the biggest, most relevant user-facing features and changes first, followed by smaller refinements, cosmetic changes, and documentation updates. Do not use implementation date or addition order. Keep the required category order and release chronology unchanged, and preserve historical descriptions, images, and links when reordering.
- **Never list development bugs**: Never list bugs discovered and fixed while developing a brand-new feature in the same unreleased version.
- **Never list internal/development iterations**: Never list layout corrections, failed implementation attempts, temporary regressions, internal rewrites, or debugging steps from the current development cycle.
- **Polished final behavior only**: If a new feature had problems while being developed, describe only its final user-visible behavior under *New Features*.
- **Strict terminology**: Do not describe something as “fixed,” “corrected,” “more reliable,” or “improved” unless the problematic behavior existed in a previously released version.
- **Internal performance work**: May be listed under *Improvements* only when it meaningfully improves a feature that was already publicly available.
- **Baseline check**: Compare against the latest public release before classifying an entry.
- **Empty categories**: If a category has no qualifying entries, write a short `"No entries recorded for this release."` message.
- **Historical integrity**: Preserve existing release descriptions, images, and links when reorganizing historical notes.
- **Consistency**: Apply the exact same policy to both `changelog.html` and GitHub Releases.

## Development and Testing Workflow

Whenever code changes are completed:
- Stop the previous DockAway debug session and quit any other running DockAway instances before launching the updated build, avoiding process conflicts and duplicate menu-bar icons.
- Use Xcode's command-line tools (CLT) by default: build this workspace with `xcodebuild -project DockAway.xcodeproj -scheme DockAway -configuration Debug build`, then launch the resulting Debug app with `open` using its exact bundle path. Resolve that path from the build settings or output rather than assuming a fixed DerivedData directory. Preserve the project's signing configuration.
- Build and launch automatically without asking the user to do it themselves or bringing Xcode forward. Keep build output in a log and report concise results to reduce token usage.
- Use Xcode UI automation only when debugger work requires it or the user explicitly requests it. Command-line launches normally run without Xcode's debugger attached.
- Verify that the build succeeds and that the running executable is the freshly built Debug app. Never launch `/Applications/DockAway.app`, a release archive, or an ambiguous bundle identifier as a substitute.
- Leave the updated Debug app running for the user to test. This replaces the previous requirement to leave DockAway terminated after coding.
- If building or launching fails, report the failure accurately and resolve it when possible. Do not present an older running build as the updated version.
