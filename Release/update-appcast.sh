#!/bin/zsh
set -euo pipefail

github_repo="akhairaddin/DockAway"
release_notes_url="https://akhairaddin.github.io/DockAway/changelog.html"
fail() { print -u2 "DockAway appcast: $*"; exit 1; }

find_generate_appcast() {
    if [[ -n "${SPARKLE_GENERATE_APPCAST:-}" && -x "$SPARKLE_GENERATE_APPCAST" ]]; then
        print -r -- "$SPARKLE_GENERATE_APPCAST"
    elif command -v generate_appcast >/dev/null 2>&1; then
        command -v generate_appcast
    else
        find "$HOME/Library/Developer/Xcode/DerivedData" \
            -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
            -type f -perm -111 -print -quit 2>/dev/null
    fi
}

repo_root="${RILMAZAFONE_REPO_ROOT:?RILMAZAFONE_REPO_ROOT is missing}"
version="${RILMAZAFONE_VERSION:?RILMAZAFONE_VERSION is missing}"
dmg_path="${RILMAZAFONE_DMG:?RILMAZAFONE_DMG is missing}"
[[ -f "$dmg_path" ]] || fail "DMG not found: $dmg_path"
cd "$repo_root"
metadata="$repo_root/Release/release_metadata.py"
generate_appcast="$(find_generate_appcast)"
[[ -n "$generate_appcast" ]] || fail "Sparkle generate_appcast was not found."

stage_dir="$(mktemp -d /private/tmp/DockAway-appcast-XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
dmg_name="$(python3 "$metadata" asset-name "$version" "$dmg_path")"
download_url="https://github.com/$github_repo/releases/download/$version/$dmg_name"
python3 "$metadata" notes changelog.html "$version" "$stage_dir/notes.md"
cp appcast.xml "$stage_dir/appcast.xml"
cp "$dmg_path" "$stage_dir/$dmg_name"

"$generate_appcast" --maximum-versions 0 \
    --download-url-prefix "https://github.com/$github_repo/releases/download/$version/" \
    --full-release-notes-url "$release_notes_url" "$stage_dir"
python3 "$metadata" normalize-feed "$stage_dir/appcast.xml" "$version" \
    "$dmg_path" "$download_url" "$release_notes_url"

# Sign and validate locally before the publisher makes any public changes.
if [[ "${DOCKAWAY_PREPARE_ONLY:-0}" == 1 ]]; then
    print "Appcast preflight passed for $version"
    exit 0
fi

# Compare the actual public bytes, not just the asset's name.
mkdir "$stage_dir/download"
gh release download "$version" --repo "$github_repo" --pattern "$dmg_name" \
    --dir "$stage_dir/download"
python3 "$metadata" verify-archive "$dmg_path" "$stage_dir/download/$dmg_name"

[[ -z "$(git status --porcelain)" ]] || fail "Commit local changes before publishing the feed."
remote_name="DockAway"
git remote get-url "$remote_name" >/dev/null 2>&1 || remote_name="origin"
remote_url="$(git remote get-url "$remote_name")"
[[ "$remote_url" == *"akhairaddin/DockAway"* ]] || fail "Unexpected Git remote."
cp "$stage_dir/appcast.xml" appcast.xml
git add appcast.xml
if ! git diff --cached --quiet; then
    git commit -m "Publish DockAway $version appcast"
fi
git push "$remote_name" HEAD:main
print "Sparkle appcast published for DockAway $version"
