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
metadata="$repo_root/Release/release_metadata.py"
stage_dir="$(mktemp -d /private/tmp/DockAway-publish-XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
dmg_name="$(python3 "$metadata" asset-name "$version" "$dmg_path")"
python3 "$metadata" notes changelog.html "$version" "$stage_dir/notes.md"
if [[ -n "$release_notes" ]]; then
    print >> "$stage_dir/notes.md"
    print -r -- "$release_notes" >> "$stage_dir/notes.md"
fi
cp "$dmg_path" "$stage_dir/$dmg_name"
DOCKAWAY_PREPARE_ONLY=1 /bin/zsh "$repo_root/Release/update-appcast.sh"

release_exists=false
if gh release view "$version" --repo "$github_repo" >/dev/null 2>&1; then
    release_exists=true
fi
# A tag can exist even when no GitHub release has been created for it yet.
if gh api "repos/$github_repo/git/ref/tags/$version" >/dev/null 2>&1; then
    tag_commit="$(gh api "repos/$github_repo/commits/$version" --jq .sha)"
    [[ "$tag_commit" == "$commit_sha" ]] \
        || fail "Tag $version points to $tag_commit, not HEAD. Use a new version or explicitly reconcile the tag first."
fi

print "Pushing release commit $commit_sha to $remote_name/main"
git push "$remote_name" HEAD:main

if $release_exists; then
    if gh release view "$version" --repo "$github_repo" --json assets \
        --jq '.assets[].name' | grep -Fx "$dmg_name" >/dev/null; then
        mkdir "$stage_dir/download"
        gh release download "$version" --repo "$github_repo" --pattern "$dmg_name" \
            --dir "$stage_dir/download"
        python3 "$metadata" verify-archive "$dmg_path" "$stage_dir/download/$dmg_name"
    else
        gh release upload "$version" "$stage_dir/$dmg_name" --repo "$github_repo"
    fi
    gh release edit "$version" --repo "$github_repo" \
        --title "DockAway $version" --notes-file "$stage_dir/notes.md"
else
    print "Creating GitHub release $version"
    gh release create "$version" "$stage_dir/$dmg_name" \
        --repo "$github_repo" --target "$commit_sha" \
        --title "DockAway $version" --notes-file "$stage_dir/notes.md"
fi

gh release view "$version" --repo "$github_repo" --json assets \
    --jq '.assets[].name' | grep -Fx "$dmg_name" >/dev/null \
    || fail "$dmg_name is missing from GitHub release $version."

print "GitHub release $version contains $dmg_name"
