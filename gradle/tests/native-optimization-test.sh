#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
media_root="$repository_root/media"
optimization_patch="$repository_root/patches/06-native-release-optimization.patch"
test_root="$(mktemp -d -t media3-native-optimization.XXXXXXXX)"

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

paths=(
    libraries/decoder_ffmpeg/build.gradle.kts
    libraries/decoder_ffmpeg/src/main/jni/CMakeLists.txt
    libraries/decoder_ffmpeg/src/main/jni/build_ffmpeg.sh
    libraries/decoder_ffmpeg/src/main/jni/build_yuv.sh
)
for path in "${paths[@]}"; do
    mkdir -p "$test_root/$(dirname "$path")"
    cp -- "$media_root/$path" "$test_root/$path"
done
chmod +x "$test_root/libraries/decoder_ffmpeg/src/main/jni/build_ffmpeg.sh"

[[ -f "$optimization_patch" ]] || fail "native optimization patch is missing"
git -C "$test_root" init -q
if git -C "$test_root" apply --reverse --check "$optimization_patch" 2>/dev/null; then
    git -C "$test_root" apply --reverse "$optimization_patch"
fi
git -C "$test_root" apply "$optimization_patch"

decoder_gradle="$test_root/${paths[0]}"
jni_cmake="$test_root/${paths[1]}"
ffmpeg_script="$test_root/${paths[2]}"
yuv_script="$test_root/${paths[3]}"

grep -Fq 'providers.gradleProperty("jellyfinAndroidNdkVersion").orNull?.let { ndkVersion = it }' "$decoder_gradle" ||
    fail "Media3 FFmpeg JNI build does not select the repository-pinned NDK"

grep -Fq -- '--optflags=-O3' "$ffmpeg_script" || fail "Media3 FFmpeg does not select O3"
grep -Fq -- '--enable-lto' "$ffmpeg_script" || fail "Media3 FFmpeg does not enable LTO"
grep -Fq -- '--host-cc=clang' "$ffmpeg_script" || fail "Media3 FFmpeg host tools do not use Clang"
[[ "$(grep -Fc -- '--enable-neon' "$ffmpeg_script")" -eq 2 ]] ||
    fail "Media3 FFmpeg must enable NEON for exactly the two ARM builds"
grep -Fq -- '-mfpu=neon' "$ffmpeg_script" || fail "Media3 FFmpeg ARMv7 does not require NEON"
[[ "$(grep -Fc -- '--enable-thumb' "$ffmpeg_script")" -eq 1 ]] ||
    fail "Media3 FFmpeg must enable Thumb only for ARMv7"

grep -Fq 'release_flags="-O3 -flto=thin"' "$yuv_script" ||
    fail "Media3 libyuv release compilation does not select O3 and thin LTO"
grep -Fq 'release_flags+=" -mthumb"' "$yuv_script" ||
    fail "Media3 libyuv ARMv7 compilation does not select Thumb-2"
grep -Fq -- '-DCMAKE_C_FLAGS_RELEASE=${release_flags}' "$yuv_script" ||
    fail "Media3 libyuv C compilation does not consume the release flags"
grep -Fq -- '-DCMAKE_CXX_FLAGS_RELEASE=${release_flags}' "$yuv_script" ||
    fail "Media3 libyuv C++ compilation does not consume the release flags"
grep -Fq -- '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=ON' "$yuv_script" ||
    fail "Media3 libyuv release linking does not enable LTO"

grep -Fq 'target_compile_options(ffmpegJNI PRIVATE -O3 -flto=thin)' "$jni_cmake" ||
    fail "Media3 FFmpeg JNI compilation does not select O3 and thin LTO"
grep -Fq 'target_link_options(ffmpegJNI PRIVATE -flto=thin)' "$jni_cmake" ||
    fail "Media3 FFmpeg JNI linking does not enable thin LTO"
grep -Fq 'target_link_options(ffmpegJNI PRIVATE -Wl,--no-fatal-warnings)' "$jni_cmake" ||
    fail "Media3 FFmpeg JNI ARMv7 link does not isolate expected vectorization failures"
grep -Fq 'target_compile_options(ffmpegJNI PRIVATE -mfpu=neon)' "$jni_cmake" ||
    fail "Media3 FFmpeg JNI ARMv7 compilation does not require NEON"
grep -Fq 'target_compile_options(ffmpegJNI PRIVATE -mthumb)' "$jni_cmake" ||
    fail "Media3 FFmpeg JNI ARMv7 compilation does not select Thumb-2"

wsl_wrapper="$repository_root/gradle/build-ffmpeg-static-wsl.sh"
gradle_build="$repository_root/gradle/aar-output.gradle.kts"
grep -Fq 'linux_toolchain_bin="${linux_ndk_root}/toolchains/llvm/prebuilt/linux-x86_64/bin"' "$wsl_wrapper" ||
    fail "Media3 WSL build wrapper does not select the Linux NDK Clang toolchain"
grep -Fq 'export PATH="${linux_toolchain_bin}:${PATH}"' "$wsl_wrapper" ||
    fail "Media3 WSL build wrapper does not put NDK Clang before distro compilers"
grep -Fq '"${linux_toolchain_bin}/clang" -x c -flto -fuse-ld=lld' "$wsl_wrapper" ||
    fail "Media3 WSL build wrapper does not smoke-test NDK Clang for host LTO"
grep -Fq 'selectedAndroidNdkVersion.get(),' "$gradle_build" ||
    fail "Media3 Gradle build does not pass the selected NDK revision to WSL"
grep -Fq '"-PjellyfinAndroidNdkVersion=${selectedAndroidNdkVersion.get()}"' "$gradle_build" ||
    fail "Media3 nested Gradle build does not receive the selected NDK revision"
if grep -Eq '^for command_name in .* clang' "$wsl_wrapper"; then
    fail "Media3 WSL build wrapper still requires a distro Clang"
fi

echo "Media3 native optimization contracts passed"
