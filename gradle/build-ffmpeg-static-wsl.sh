#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 <module-path> <ndk-revision> <build-script> <android-api> <decoder...>" >&2
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' was not found inside WSL."
}

require_directory() {
    [[ -d "$1" ]] || fail "$2: $1"
}

require_file() {
    [[ -f "$1" ]] || fail "$2: $1"
}

if (($# < 5)); then
    usage
    exit 2
fi

module_path="$1"
ndk_revision="$2"
build_script="$3"
android_api="$4"
shift 4
readonly module_path ndk_revision build_script android_api
readonly -a decoders=("$@")

[[ "${android_api}" =~ ^[0-9]+$ ]] || fail "Android API must be a positive integer: ${android_api}"
((android_api > 0)) || fail "Android API must be a positive integer: ${android_api}"
[[ "${ndk_revision}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Only stable numeric NDK revisions are supported: ${ndk_revision}"

for command_name in make git tar tr mktemp wget unzip; do
    require_command "${command_name}"
done

require_directory "${module_path}" "FFmpeg module path does not exist in WSL"
require_file "${build_script}" "Media3 FFmpeg build script does not exist in WSL"

ndk_major="${ndk_revision%%.*}"
ndk_release="r${ndk_major}"
ndk_cache_parent="/tmp/jellyfin-media3-ndk-cache"
linux_ndk_root="${ndk_cache_parent}/android-ndk-${ndk_revision}"
readonly ndk_major ndk_release ndk_cache_parent linux_ndk_root

validate_linux_ndk() {
    local root="$1"
    local source_properties="${root}/source.properties"
    local declared_revision

    require_file "${source_properties}" "Linux NDK source.properties is missing"
    declared_revision="$(sed -n 's/^[[:space:]]*Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "${source_properties}" | head -n 1)"
    [[ "${declared_revision}" == "${ndk_revision}" ]] ||
        fail "Linux NDK revision mismatch: expected ${ndk_revision}, found ${declared_revision:-unknown}"
    require_file \
        "${root}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" \
        "Linux NDK Clang is missing"
}

if [[ ! -d "${linux_ndk_root}" ]]; then
    mkdir -p "${ndk_cache_parent}"
    ndk_download_root="$(mktemp -d "/tmp/jellyfin-media3-ndk-download.${ndk_revision}.XXXXXX")"
    readonly ndk_download_root
    trap 'rm -rf -- "${ndk_download_root}"' EXIT
    ndk_archive="${ndk_download_root}/android-ndk-${ndk_release}-linux.zip"
    readonly ndk_archive

    wget \
        "https://dl.google.com/android/repository/android-ndk-${ndk_release}-linux.zip" \
        -O "${ndk_archive}"
    unzip -q "${ndk_archive}" -d "${ndk_download_root}"
    extracted_ndk="${ndk_download_root}/android-ndk-${ndk_release}"
    readonly extracted_ndk
    validate_linux_ndk "${extracted_ndk}"
    mv "${extracted_ndk}" "${linux_ndk_root}"
fi
validate_linux_ndk "${linux_ndk_root}"

linux_toolchain_bin="${linux_ndk_root}/toolchains/llvm/prebuilt/linux-x86_64/bin"
readonly linux_toolchain_bin
export PATH="${linux_toolchain_bin}:${PATH}"

android_api_64="${android_api}"
if ((android_api_64 < 21)); then
    android_api_64=21
fi
readonly android_api_64

for tool in \
    clang clang++ llvm-ar llvm-nm llvm-ranlib llvm-strip \
    "armv7a-linux-androideabi${android_api}-clang" \
    "aarch64-linux-android${android_api_64}-clang" \
    "i686-linux-android${android_api}-clang" \
    "x86_64-linux-android${android_api_64}-clang"; do
    require_file "${linux_toolchain_bin}/${tool}" "Required Linux NDK tool is missing"
done

ffmpeg_link="${module_path}/jni/ffmpeg"
readonly ffmpeg_link
require_directory "${ffmpeg_link}" "Media3 FFmpeg source link is missing in WSL"

# FFmpeg builds all ABIs in the same source tree. Remove only generated build
# state before starting so an interrupted/repeated build cannot retain archive
# members from a previously compiled ABI.
if [[ -f "${ffmpeg_link}/Makefile" ]]; then
    make -C "${ffmpeg_link}" distclean >/dev/null
fi
rm -rf -- "${ffmpeg_link}/android-libs"

mkdir -p "${ffmpeg_link}/ffbuild-tmp"
export TMPDIR="${ffmpeg_link}/ffbuild-tmp"

# NDK Clang's generic Linux driver must produce runnable host utilities with
# LTO, while its target-prefixed driver must produce Android objects.
compiler_test_dir="${TMPDIR}/toolchain-test"
readonly compiler_test_dir
rm -rf -- "${compiler_test_dir}"
mkdir -p "${compiler_test_dir}"
printf 'int main(void) { return 0; }\n' >"${compiler_test_dir}/host.c"
printf 'int jellyfin_ndk_test(void) { return 0; }\n' >"${compiler_test_dir}/android.c"
(
    cd "${compiler_test_dir}"
    "${linux_toolchain_bin}/clang" -x c -flto -fuse-ld=lld host.c -o host-test
    ./host-test
    "${linux_toolchain_bin}/aarch64-linux-android${android_api_64}-clang" \
        -c android.c -o android.o
)
require_file "${compiler_test_dir}/android.o" "Linux NDK Android compiler test did not produce an object file"
rm -rf -- "${compiler_test_dir}"

normalized_build_script="$(mktemp "/tmp/jellyfin-media3-build-ffmpeg.XXXXXX.sh")"
readonly normalized_build_script
if [[ -n "${ndk_download_root-}" ]]; then
    trap 'rm -rf -- "${ndk_download_root}"; rm -f -- "${normalized_build_script}"' EXIT
else
    trap 'rm -f -- "${normalized_build_script}"' EXIT
fi
tr -d '\r' <"${build_script}" >"${normalized_build_script}"

export JOBS="${FFMPEG_JOBS:-4}"

bash "${normalized_build_script}" \
    "${module_path}" \
    "${linux_ndk_root}" \
    linux-x86_64 \
    "${android_api}" \
    "${decoders[@]}"
