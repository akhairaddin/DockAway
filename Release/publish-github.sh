#!/bin/zsh

set -euo pipefail

github_repo="akhairaddin/DockAway"
preferred_remote="DockAway"

fail() {
    print -u2 "DockAway release: $*"
    exit 1
}

repo_root="${RILMAZAFONE_REPO_ROOT:-}"
version="${RILMAZAFONE_VERSION:-}"
dmg_path="${RILMAZAFONE_DMG:-}"
release_notes="${RILMAZAFONE_NOTES:-}"

[[ -n "$repo_root" ]] || fail "RILMAZAFONE_REPO_ROOT is missing."
[[ -n "$version" ]] || fail "RILMAZAFONE_VERSION is missing."
[[ -n "$dmg_path" ]] || fail "RILMAZAFONE_DMG is missing."
[[ -f "$dmg_path" ]] || fail "DMG not found at $dmg_path"

cd "$repo_root"

[[ -z "$(git status --porcelain)" ]] \
    || fail "The repository has uncommitted files. Commit them before publishing."

gh auth status >/dev/null 2>&1 \
    || fail "GitHub CLI is not authenticated. Run: gh auth login"

remote_name="$preferred_remote"
if ! git remote get-url "$remote_name" >/dev/null 2>&1; then
    remote_name="origin"
fi
git remote get-url "$remote_name" >/dev/null 2>&1 \
    || fail "Neither the DockAway nor origin Git remote exists."

remote_url="$(git remote get-url "$remote_name")"
[[ "$remote_url" == *"akhairaddin/DockAway"* ]] \
    || fail "Refusing to publish through unexpected remote: $remote_url"

commit_sha="$(git rev-parse HEAD)"
dmg_name="$(basename "$dmg_path")"

print "Pushing release commit $commit_sha to $remote_name/main"
git push "$remote_name" HEAD:main

if gh release view "$version" --repo "$github_repo" >/dev/null 2>&1; then
    print "Release $version already exists. Replacing $dmg_name."
    gh release upload "$version" "$dmg_path" --repo "$github_repo" --clobber
    if [[ -n "$release_notes" ]]; then
        gh release edit "$version" \
            --repo "$github_repo" \
            --target "$commit_sha" \
            --title "DockAway $version" \
            --notes "$release_notes"
    fi
else
    print "Creating GitHub release $version"
    if [[ -n "$release_notes" ]]; then
        gh release create "$version" "$dmg_path" \
            --repo "$github_repo" \
            --target "$commit_sha" \
            --title "DockAway $version" \
            --notes "$release_notes"
    else
        gh release create "$version" "$dmg_path" \
            --repo "$github_repo" \
            --target "$commit_sha" \
            --title "DockAway $version" \
            --generate-notes
    fi
fi

gh release view "$version" --repo "$github_repo" --json assets \
    --jq '.assets[].name' | grep -Fx "$dmg_name" >/dev/null \
    || fail "$dmg_name is missing from GitHub release $version."

print "GitHub release $version contains $dmg_name"
