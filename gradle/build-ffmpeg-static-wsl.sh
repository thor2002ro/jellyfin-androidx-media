#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 <module-path> <windows-toolchain-bin> <build-script> <android-api> <decoder...>" >&2
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
windows_toolchain_bin="$2"
build_script="$3"
android_api="$4"
shift 4
readonly module_path windows_toolchain_bin build_script android_api
readonly -a decoders=("$@")

[[ "${android_api}" =~ ^[0-9]+$ ]] || fail "Android API must be a positive integer: ${android_api}"
((android_api > 0)) || fail "Android API must be a positive integer: ${android_api}"

for command_name in make git tar tr mktemp wslpath; do
    require_command "${command_name}"
done

require_directory "${module_path}" "FFmpeg module path does not exist in WSL"
require_directory "${windows_toolchain_bin}" "Windows NDK toolchain directory does not exist in WSL"
require_file "${build_script}" "Media3 FFmpeg build script does not exist in WSL"

for tool in clang.exe clang++.exe llvm-ar.exe llvm-nm.exe llvm-ranlib.exe llvm-strip.exe; do
    require_file "${windows_toolchain_bin}/${tool}" "Required Windows NDK tool is missing"
done

wrap_root="$(mktemp -d "/tmp/jellyfin-android-ndk-winwrap-${android_api}.XXXXXX")"
readonly wrap_root
trap 'rm -rf "${wrap_root}"' EXIT

wrap_ndk="${wrap_root}/ndk"
wrap_bin="${wrap_ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin"
readonly wrap_ndk wrap_bin
mkdir -p "${wrap_bin}"

# Media3's FFmpeg script expects Linux-style NDK executables. These small
# wrappers translate mounted WSL paths, then call the Windows NDK tools.
write_windows_tool_wrapper() {
    local output="$1"
    local executable="$2"
    shift 2
    local -a extra_args=("$@")
    local quoted_executable
    local extra

    printf -v quoted_executable '%q' "${executable}"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        printf 'executable=%s\n' "${quoted_executable}"
        echo 'converted=()'
        echo 'for argument in "$@"; do'
        cat <<'SCRIPT'
    case "${argument}" in
        /mnt/*)
            argument="$(wslpath -w "${argument}")"
            ;;
        -I/mnt/*)
            argument="-I$(wslpath -w "${argument#-I}")"
            ;;
        -L/mnt/*)
            argument="-L$(wslpath -w "${argument#-L}")"
            ;;
        --sysroot=/mnt/*)
            argument="--sysroot=$(wslpath -w "${argument#--sysroot=}")"
            ;;
        @/mnt/*)
            argument="@$(wslpath -w "${argument#@}")"
            ;;
    esac
    converted+=("${argument}")
done
SCRIPT
        printf 'exec "${executable}"'
        for extra in "${extra_args[@]}"; do
            printf ' %q' "${extra}"
        done
        echo ' "${converted[@]}"'
    } >"${output}"
    chmod +x "${output}"
}

create_target_wrappers() {
    local triple="$1"
    local api="$2"
    local target="${triple}${api}"

    write_windows_tool_wrapper \
        "${wrap_bin}/${triple}${api}-clang" \
        "${windows_toolchain_bin}/clang.exe" \
        "--target=${target}"
    write_windows_tool_wrapper \
        "${wrap_bin}/${triple}${api}-gcc" \
        "${windows_toolchain_bin}/clang.exe" \
        "--target=${target}"
    write_windows_tool_wrapper \
        "${wrap_bin}/${triple}${api}-clang++" \
        "${windows_toolchain_bin}/clang++.exe" \
        "--target=${target}"
    write_windows_tool_wrapper \
        "${wrap_bin}/${triple}${api}-g++" \
        "${windows_toolchain_bin}/clang++.exe" \
        "--target=${target}"
}

write_windows_tool_wrapper "${wrap_bin}/llvm-ar" "${windows_toolchain_bin}/llvm-ar.exe"
write_windows_tool_wrapper "${wrap_bin}/llvm-nm" "${windows_toolchain_bin}/llvm-nm.exe"
write_windows_tool_wrapper "${wrap_bin}/llvm-ranlib" "${windows_toolchain_bin}/llvm-ranlib.exe"
write_windows_tool_wrapper "${wrap_bin}/llvm-strip" "${windows_toolchain_bin}/llvm-strip.exe"

android_api_64="${android_api}"
if ((android_api_64 < 21)); then
    android_api_64=21
fi
readonly android_api_64

create_target_wrappers armv7a-linux-androideabi "${android_api}"
create_target_wrappers aarch64-linux-android "${android_api_64}"
create_target_wrappers i686-linux-android "${android_api}"
create_target_wrappers x86_64-linux-android "${android_api_64}"

ffmpeg_link="${module_path}/jni/ffmpeg"
readonly ffmpeg_link
require_directory "${ffmpeg_link}" "Media3 FFmpeg source link is missing in WSL"

# FFmpeg builds all ABIs in the same source tree. Remove only generated build
# state before starting so an interrupted/repeated build cannot retain archive
# members from a previously compiled ABI.
if [[ -f "${ffmpeg_link}/Makefile" ]]; then
    make -C "${ffmpeg_link}" distclean >/dev/null
fi
rm -rf "${ffmpeg_link}/android-libs"

mkdir -p "${ffmpeg_link}/ffbuild-tmp"
export TMPDIR="${ffmpeg_link}/ffbuild-tmp"

# Fail early with a tiny compilation instead of surfacing an opaque FFmpeg
# configure error when WSL cannot execute the Windows compiler correctly.
compiler_test_dir="${TMPDIR}/toolchain-test"
readonly compiler_test_dir
rm -rf "${compiler_test_dir}"
mkdir -p "${compiler_test_dir}"
printf 'int jellyfin_ndk_test(void) { return 0; }\n' >"${compiler_test_dir}/test.c"
(
    cd "${compiler_test_dir}"
    "${wrap_bin}/aarch64-linux-android${android_api_64}-gcc" -c test.c -o test.o
)
require_file "${compiler_test_dir}/test.o" "Windows NDK compiler interoperability test did not produce an object file"
rm -rf "${compiler_test_dir}"

# The upstream script can be checked out with CRLF line endings on Windows.
normalized_build_script="${wrap_root}/build_ffmpeg.sh"
readonly normalized_build_script
tr -d '\r' <"${build_script}" >"${normalized_build_script}"

# Each make job launches a Windows compiler through WSL. Keeping this bounded
# avoids exhausting the WSL transport on high-core-count hosts.
export JOBS="${FFMPEG_JOBS:-4}"

bash "${normalized_build_script}" \
    "${module_path}" \
    "${wrap_ndk}" \
    linux-x86_64 \
    "${android_api}" \
    "${decoders[@]}"
