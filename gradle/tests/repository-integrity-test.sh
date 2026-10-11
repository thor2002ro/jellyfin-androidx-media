#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d -t media3-repository-integrity.XXXXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if grep -Eq 'prepareFfmpeg(Source|Prebuilt)Dependencies' \
    "$repository_root/update-repo.bat" "$repository_root/update-repo.sh"; then
    fail "Build wrappers must let buildMedia3Aars select the shared or static FFmpeg preparation path."
fi

grep -Fq 'ffmpeg_ref="${FFMPEG_REF:-${3:-master}}"' "$repository_root/update-repo.sh" ||
    fail "The Media3 wrapper must keep FFmpeg on its configured moving master ref by default."
if grep -Fq 'if [[ -z "${shared_ffmpeg_aar}" ]]; then' "$repository_root/update-repo.sh"; then
    fail "The Media3 wrapper must fetch its configured FFmpeg ref before every source preparation."
fi

# Load the source helpers without running the build entry point.
eval "$(sed -n '/^git_in() {/,/^update_ffmpeg_source() {/p' \
    "$repository_root/update-repo.sh" | sed '$d')"
eval "$(sed -n '/^update_ffmpeg_source() {/,/^fetch_media_refs() {/p' \
    "$repository_root/update-repo.sh" | sed '$d')"

upstream="$test_root/upstream"
git init -q -b master "$upstream"
git -C "$upstream" config core.autocrlf false
git -C "$upstream" config user.name 'Source test'
git -C "$upstream" config user.email 'source-test@jellyfin.invalid'
printf 'initial\n' > "$upstream/source.txt"
git -C "$upstream" add source.txt
git -C "$upstream" commit -qm initial

for path in media ffmpeg; do
    checkout="$test_root/$path"
    ensure_source "$checkout" "$upstream"
    [[ -d "$checkout/.git" ]] || fail "$path was not cloned"
    git -C "$checkout" checkout -q --detach HEAD
    printf 'local edit\n' > "$checkout/source.txt"
    printf 'generated\n' > "$checkout/generated.txt"
    ensure_source "$checkout" "$upstream"
    git -C "$checkout" diff --quiet || fail "$path tracked edits survived reset"
    [[ ! -e "$checkout/generated.txt" ]] || fail "$path generated files survived cleanup"
done

ffmpeg_root="$test_root/ffmpeg"
ffmpeg_url="$upstream"
ffmpeg_ref=master
printf 'updated\n' > "$upstream/source.txt"
git -C "$upstream" commit -qam update
update_ffmpeg_source
[[ "$(git -C "$ffmpeg_root" rev-parse HEAD)" == "$(git -C "$upstream" rev-parse master)" ]] ||
    fail "FFmpeg did not fetch the updated master ref"
git -C "$upstream" checkout -qb alternate
printf 'alternate\n' > "$upstream/source.txt"
git -C "$upstream" commit -qam alternate
ffmpeg_ref=alternate
update_ffmpeg_source
[[ "$(git -C "$ffmpeg_root" rev-parse HEAD)" == "$(git -C "$upstream" rev-parse alternate)" ]] ||
    fail "FFmpeg did not switch to the requested ref"

# Existing checkouts may retain a submodule-style .git file after migration.
git clone -q --separate-git-dir="$test_root/retained-git" "$upstream" "$test_root/retained"
ensure_source "$test_root/retained" "$upstream"
[[ -f "$test_root/retained/.git" ]] || fail "Existing Git metadata was replaced"

eval "$(sed -n '/^fetch_media_refs() {/,/^ensure_libyuv_source() {/p' \
    "$repository_root/update-repo.sh" | sed '$d')"
media_root="$test_root/media"
media_version=release
media_prs=()
git -C "$upstream" branch main
git -C "$upstream" branch release
mkdir -p "$test_root/patches"
printf 'patched\n' > "$upstream/source.txt"
git -C "$upstream" diff > "$test_root/patches/01-source.patch"
git -C "$upstream" restore source.txt
repo_root="$test_root"
for iteration in 1 2; do
    ensure_source "$media_root" "$upstream"
    fetch_media_refs
    git_in "$media_root" checkout --detach "$(resolve_media_ref)"
    ensure_git_identity
    apply_local_patches
    [[ "$(cat "$media_root/source.txt")" == patched ]] || fail "Media3 patch was not applied"
    [[ "$(git_in "$media_root" rev-list --count origin/release..HEAD)" == 1 ]] ||
        fail "Repeated preparation stacked patch commits"
done

temporary_output="$test_root/output"
mkdir -p "$temporary_output/android-libs/arm64-v8a"
printf 'stale archive\n' > "$temporary_output/android-libs/arm64-v8a/libavcodec.a"
"$repository_root/gradlew" -q --no-daemon \
    -PoutputDir="$temporary_output" \
    cleanAarOutput
[[ ! -e "$temporary_output/android-libs" ]] ||
    fail "cleanAarOutput retained obsolete static FFmpeg archives"

"$repository_root/gradlew" -q --no-daemon verifyPublishedMedia3Repository

echo "Media3 repository integrity contracts passed"
