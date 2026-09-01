#!/bin/zsh

set -euo pipefail

github_repo="akhairaddin/DockAway"
preferred_remote="DockAway"
feed_url="https://akhairaddin.github.io/DockAway/appcast.xml"
release_notes_url="https://akhairaddin.github.io/DockAway/changelog.html"

fail() {
    print -u2 "DockAway appcast: $*"
    exit 1
}

find_generate_appcast() {
    if [[ -n "${SPARKLE_GENERATE_APPCAST:-}" \
          && -x "${SPARKLE_GENERATE_APPCAST:-}" ]]; then
        print -r -- "${SPARKLE_GENERATE_APPCAST:-}"
        return
    fi

    if command -v generate_appcast >/dev/null 2>&1; then
        command -v generate_appcast
        return
    fi

    local derived_data="$HOME/Library/Developer/Xcode/DerivedData"
    local candidate=""
    if [[ -d "$derived_data" ]]; then
        candidate="$(find "$derived_data" \
            -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
            -type f -perm -111 -print -quit 2>/dev/null || true)"
    fi
    [[ -n "$candidate" ]] || return 1
    print -r -- "$candidate"
}

repo_root="${RILMAZAFONE_REPO_ROOT:-}"
version="${RILMAZAFONE_VERSION:-}"
dmg_path="${RILMAZAFONE_DMG:-}"

[[ -n "$repo_root" ]] || fail "RILMAZAFONE_REPO_ROOT is missing."
[[ -n "$version" ]] || fail "RILMAZAFONE_VERSION is missing."
[[ -n "$dmg_path" ]] || fail "RILMAZAFONE_DMG is missing."
[[ -f "$dmg_path" ]] || fail "DMG not found at $dmg_path"

generate_appcast="$(find_generate_appcast)" \
    || fail "Sparkle's generate_appcast tool was not found in Xcode DerivedData."

cd "$repo_root"

appcast_path="$repo_root/appcast.xml"
[[ -f "$appcast_path" ]] || fail "appcast.xml is missing from the repository root."

dmg_name="$(basename "$dmg_path")"
gh release view "$version" --repo "$github_repo" --json assets \
    --jq '.assets[].name' | grep -Fx "$dmg_name" >/dev/null \
    || fail "GitHub release $version does not contain $dmg_name."

stage_dir="$(mktemp -d /private/tmp/DockAway-appcast-XXXXXX)"
cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

cp "$appcast_path" "$stage_dir/appcast.xml"
cp "$dmg_path" "$stage_dir/$dmg_name"

download_prefix="https://github.com/$github_repo/releases/download/$version/"
"$generate_appcast" \
    --maximum-versions 0 \
    --download-url-prefix "$download_prefix" \
    --full-release-notes-url "$release_notes_url" \
    "$stage_dir"

generated_appcast="$stage_dir/appcast.xml"
expected_version="<sparkle:shortVersionString>$version</sparkle:shortVersionString>"
expected_download="$download_prefix$dmg_name"

grep -F "$expected_version" "$generated_appcast" >/dev/null \
    || fail "Generated appcast does not contain version $version."
grep -F "$expected_download" "$generated_appcast" >/dev/null \
    || fail "Generated appcast does not contain the GitHub DMG URL."
grep -F 'sparkle:edSignature=' "$generated_appcast" >/dev/null \
    || fail "Generated appcast does not contain a Sparkle signature."

cp "$generated_appcast" "$appcast_path"
git add appcast.xml

if git diff --cached --quiet; then
    print "appcast.xml already contains DockAway $version"
else
    git commit -m "Publish DockAway $version appcast"
fi

remote_name="$preferred_remote"
if ! git remote get-url "$remote_name" >/dev/null 2>&1; then
    remote_name="origin"
fi
git remote get-url "$remote_name" >/dev/null 2>&1 \
    || fail "Neither the DockAway nor origin Git remote exists."

git push "$remote_name" HEAD:main

print "Sparkle appcast published for DockAway $version"
print "Feed: $feed_url"
