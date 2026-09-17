#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="${repository_root}/gradle/build-ffmpeg-static-wsl.sh"
test_root="$(mktemp -d -t media3-ffmpeg-wsl.XXXXXXXX)"
ndk_revision="0.0.${BASHPID}"
ndk_root="/tmp/jellyfin-media3-ndk-cache/android-ndk-${ndk_revision}"
trap 'rm -rf -- "$test_root" "$ndk_root"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

fake_bin="${test_root}/bin"
toolchain_bin="${ndk_root}/toolchains/llvm/prebuilt/linux-x86_64/bin"
module_root="${test_root}/module"
ffmpeg_root="${module_root}/jni/ffmpeg"
make_marker="${test_root}/make-invocations"
build_script="${test_root}/build_ffmpeg.sh"
mkdir -p "${fake_bin}" "${toolchain_bin}" "${ffmpeg_root}/ffbuild"

printf 'Pkg.Revision = %s\n' "${ndk_revision}" >"${ndk_root}/source.properties"
cat >"${toolchain_bin}/clang" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (($# > 0)); do
    if [[ "$1" == "-o" ]]; then
        output="$2"
        break
    fi
    shift
done
[[ -n "${output}" ]]
if [[ "${output}" == *host-test ]]; then
    printf '#!/usr/bin/env bash\nexit 0\n' >"${output}"
    chmod +x "${output}"
else
    : >"${output}"
fi
SCRIPT
chmod +x "${toolchain_bin}/clang"

for tool in \
    clang++ llvm-ar llvm-nm llvm-ranlib llvm-strip \
    armv7a-linux-androideabi23-clang aarch64-linux-android23-clang \
    i686-linux-android23-clang x86_64-linux-android23-clang; do
    cp "${toolchain_bin}/clang" "${toolchain_bin}/${tool}"
done

cat >"${fake_bin}/make" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MAKE_MARKER}"
SCRIPT
chmod +x "${fake_bin}/make"
for tool in wget unzip; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${fake_bin}/${tool}"
    chmod +x "${fake_bin}/${tool}"
done
printf '#!/usr/bin/env bash\nexit 0\n' >"${build_script}"
chmod +x "${build_script}"
touch "${ffmpeg_root}/Makefile"

export MAKE_MARKER="${make_marker}"
PATH="${fake_bin}:${PATH}" bash "${helper}" \
    "${module_root}" "${ndk_revision}" "${build_script}" 23 h264
[[ ! -e "${make_marker}" ]] ||
    fail "An unconfigured FFmpeg checkout must not run make distclean"

touch "${ffmpeg_root}/ffbuild/config.mak"
PATH="${fake_bin}:${PATH}" bash "${helper}" \
    "${module_root}" "${ndk_revision}" "${build_script}" 23 h264
grep -Fq -- "-C ${ffmpeg_root} distclean" "${make_marker}" ||
    fail "A configured FFmpeg checkout must run make distclean"

echo "WSL FFmpeg cleanup contracts passed"
