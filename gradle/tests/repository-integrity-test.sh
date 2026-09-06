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

verify_gitlink() {
    local path="$1"
    local url
    local commit
    local checked_out_commit
    url="$(git -C "$repository_root" config -f .gitmodules "submodule.$path.url")"
    commit="$(git -C "$repository_root" ls-tree HEAD -- "$path" | awk '{print $3}')"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid $path gitlink: $commit"
    checked_out_commit="$(git -C "$repository_root/$path" rev-parse HEAD)"
    [[ "$checked_out_commit" == "$commit" ]] ||
        fail "$path checkout $checked_out_commit does not match recorded gitlink $commit"
    mkdir "$test_root/$path"
    git -C "$test_root/$path" init -q
    git -C "$test_root/$path" fetch -q --depth=1 "$url" "$commit" ||
        fail "$path gitlink $commit is not fetchable from $url"
}

verify_gitlink media
verify_gitlink ffmpeg

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
