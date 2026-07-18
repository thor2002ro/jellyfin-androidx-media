#!/bin/bash

set -euo pipefail

# Ensure NDK is available
export ANDROID_NDK_PATH="${ANDROID_HOME:?ANDROID_HOME is not set}/ndk/26.1.10909125"

[[ ! -d "$ANDROID_NDK_PATH" ]] && echo "No NDK found, quitting…" && exit 1

# Build the selected Media3 PRs in the media submodule.
MEDIA_PRS=(3280:main 3271:main 3276:release 3151:main 3055:release 3092:release 3330:main)
FFMPEG_VIDEO_COMMITS=(3e4245768dc3cd4490944e5a3c94a528302ffb46 bb281936ca6b945d8f646fef49b62a63eb92f6a3 9a4a2820b9bf6063bc6ebc064045f1f191af2d27 24cc94504f5aa59bf0e8310d01c9d10055e5afe8 53bc7dfe288635b63208dd805f19e3943684bb92 00ef1b5dddb2e5b1141de6ca976b978108328319 57346bbf36a7456e99008298cf55ce16011401db)
REPO_ROOT="$(pwd)"
MEDIA_VERSION="${MEDIA_VERSION:-${1:-}}"
MEDIA_BUILD_ROOT="${REPO_ROOT}/media"
FFMPEG_PATH="${REPO_ROOT}/ffmpeg"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/OUTPUT}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

reset_build_submodules_to_recorded_commits() {
    jni_root="${MEDIA_BUILD_ROOT}/libraries/decoder_ffmpeg/src/main/jni"
    rm -rf "${jni_root}/ffmpeg"
    rm -rf "${jni_root}/libyuv"
    media_commit="$(git -C "${REPO_ROOT}" ls-files --stage -- media | awk '$1 == "160000" { print $2 }')"
    ffmpeg_commit="$(git -C "${REPO_ROOT}" ls-files --stage -- ffmpeg | awk '$1 == "160000" { print $2 }')"
    [[ -n "${media_commit}" && -n "${ffmpeg_commit}" ]] || {
        echo "Failed to read recorded media or ffmpeg submodule commit"
        exit 1
    }
    git -C "${MEDIA_BUILD_ROOT}" checkout --detach "${media_commit}"
    git -C "${MEDIA_BUILD_ROOT}" reset --hard
    git -C "${MEDIA_BUILD_ROOT}" clean -ffdx
    git -C "${FFMPEG_PATH}" checkout --detach "${ffmpeg_commit}"
    git -C "${FFMPEG_PATH}" reset --hard
    git -C "${FFMPEG_PATH}" clean -ffdx
}

reset_build_submodules_to_recorded_commits
git -C "${MEDIA_BUILD_ROOT}" config core.autocrlf false
git -C "${FFMPEG_PATH}" config core.autocrlf false
git -C "${FFMPEG_PATH}" grep -Ilz '.' | xargs -0 sed -i 's/\r$//'
git -C "${MEDIA_BUILD_ROOT}" remote set-url origin https://github.com/androidx/media.git

git -C "${MEDIA_BUILD_ROOT}" fetch origin --tags main release
MEDIA_VERSION="${MEDIA_VERSION:-origin/main}"
if git -C "${MEDIA_BUILD_ROOT}" rev-parse --verify --quiet "${MEDIA_VERSION}" >/dev/null; then
    :
elif git -C "${MEDIA_BUILD_ROOT}" rev-parse --verify --quiet "origin/${MEDIA_VERSION}" >/dev/null; then
    MEDIA_VERSION="origin/${MEDIA_VERSION}"
elif git -C "${MEDIA_BUILD_ROOT}" rev-parse --verify --quiet "refs/tags/${MEDIA_VERSION}" >/dev/null; then
    MEDIA_VERSION="refs/tags/${MEDIA_VERSION}"
else
    echo "No Media3 ref found: ${MEDIA_VERSION}"
    exit 1
fi
echo "Building Media3 ${MEDIA_VERSION}"
git -C "${MEDIA_BUILD_ROOT}" checkout --detach "${MEDIA_VERSION}"
git -C "${MEDIA_BUILD_ROOT}" fetch origin refs/pull/1591/head
for commit in "${FFMPEG_VIDEO_COMMITS[@]}"; do
    if ! git -C "${MEDIA_BUILD_ROOT}" cherry-pick --no-commit "${commit}"; then
        [[ "${commit}" == "${FFMPEG_VIDEO_COMMITS[0]}" ]] || exit 1
        git -C "${MEDIA_BUILD_ROOT}" checkout --ours -- libraries/decoder_ffmpeg/README.md
        git -C "${MEDIA_BUILD_ROOT}" rm -- libraries/decoder_ffmpeg/build.gradle
        git -C "${MEDIA_BUILD_ROOT}" checkout --theirs -- libraries/decoder_ffmpeg/src/main/java/androidx/media3/decoder/ffmpeg/ExperimentalFfmpegVideoRenderer.java
        git -C "${MEDIA_BUILD_ROOT}" add libraries/decoder_ffmpeg
    fi
    git -C "${MEDIA_BUILD_ROOT}" commit --reuse-message="${commit}"
done
for entry in "${MEDIA_PRS[@]}"; do
    pr="${entry%%:*}"
    branch="${entry#*:}"
    ref="refs/media-build/pr-${pr}"
    git -C "${MEDIA_BUILD_ROOT}" fetch origin "refs/pull/${pr}/head:${ref}"
    commits="$(git -C "${MEDIA_BUILD_ROOT}" rev-list --reverse --no-merges --cherry-pick --right-only "origin/${branch}...${ref}")"
    for commit in ${commits}; do
        if ! git -C "${MEDIA_BUILD_ROOT}" cherry-pick --no-commit "${commit}"; then
            conflicts="$(git -C "${MEDIA_BUILD_ROOT}" diff --name-only --diff-filter=U)"
            [[ "${conflicts}" == "RELEASENOTES.md" ]] || exit 1
            git -C "${MEDIA_BUILD_ROOT}" checkout --ours -- RELEASENOTES.md
            git -C "${MEDIA_BUILD_ROOT}" add RELEASENOTES.md
        fi
        git -C "${MEDIA_BUILD_ROOT}" commit --reuse-message="${commit}"
    done
done

git -C "${MEDIA_BUILD_ROOT}" apply "${REPO_ROOT}/patches/ffmpeg-video-codecs.patch"

# Setup environment
export ANDROIDX_MEDIA_ROOT="${MEDIA_BUILD_ROOT}"
export FFMPEG_MOD_PATH="${ANDROIDX_MEDIA_ROOT}/libraries/decoder_ffmpeg/src/main"
export ENABLED_DECODERS=(
    flac alac pcm_mulaw pcm_alaw mp3 aac ac3 eac3 dca truehd
    vorbis opus amrnb amrwb gsm_ms
    mpeg1video mpeg2video h263 vp8 vp9 h264 hevc
    msmpeg4v2 msmpeg4v3 mpeg4 vc1
)

# Create the native dependency link.
rm -rf "${FFMPEG_MOD_PATH}/jni/ffmpeg"
ln -s "${FFMPEG_PATH}" "${FFMPEG_MOD_PATH}/jni/ffmpeg"
git clone --depth 1 --branch main https://chromium.googlesource.com/libyuv/libyuv "${FFMPEG_MOD_PATH}/jni/libyuv"

# Start build
cd "${FFMPEG_MOD_PATH}/jni"
./build_ffmpeg.sh "${FFMPEG_MOD_PATH}" "${ANDROID_NDK_PATH}" "linux-x86_64" 23 "${ENABLED_DECODERS[@]}"

for abi in armeabi-v7a arm64-v8a x86 x86_64; do
    for lib in libavcodec.a libavutil.a libswresample.a libswscale.a; do
        [[ -f "${FFMPEG_PATH}/android-libs/${abi}/${lib}" ]] || {
            echo "Missing FFmpeg library: ${abi}/${lib}"
            exit 1
        }
    done
done

rm -rf "${OUTPUT_DIR}/android-libs"
cp -R "${FFMPEG_PATH}/android-libs" "${OUTPUT_DIR}/android-libs"

(
    cd "${MEDIA_BUILD_ROOT}"
    ./gradlew :lib-decoder-ffmpeg:assembleRelease
)

AAR_PATH="${MEDIA_BUILD_ROOT}/libraries/decoder_ffmpeg/buildout/outputs/aar/lib-decoder-ffmpeg-release.aar"
[[ -f "${AAR_PATH}" ]] || {
    echo "Built decoder AAR was not found: ${AAR_PATH}"
    exit 1
}
AAR_OUTPUT="${OUTPUT_DIR}/media3-ffmpeg-decoder-latest-SNAPSHOT.aar"
cp "${AAR_PATH}" "${AAR_OUTPUT}"
reset_build_submodules_to_recorded_commits
echo "Built AAR: ${AAR_OUTPUT}"
