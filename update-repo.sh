#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./update-repo.sh [options] [media-ref] [merge-ref] [ffmpeg-ref]

Prepare the patched AndroidX Media checkout, then build Jellyfin's Media3 AARs.

Options:
  --prepare-only  Update and patch the source trees, but do not run Gradle.
  --build-only    Reuse the prepared source trees and run only the build.
  -h, --help      Show this help text.

Environment overrides:
  MEDIA_VERSION, MEDIA_MERGE_VERSION, FFMPEG_REF, FFMPEG_URL,
  FFMPEG_STATIC_MODE (source|prebuilt), and OUTPUT_DIR.
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    local command_name="$1"
    local message="${2:-${command_name} is required.}"

    command -v "${command_name}" >/dev/null 2>&1 || fail "${message}"
}

prepare_only=false
build_only=false
restore_only=false
while (($# > 0)); do
    case "$1" in
        --prepare-only)
            prepare_only=true
            shift
            ;;
        --build-only)
            build_only=true
            shift
            ;;
        --restore-only)
            restore_only=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
aar_gradle_script="${repo_root}/gradle/aar-output.gradle.kts"
media_root="${repo_root}/media"
ffmpeg_root="${repo_root}/ffmpeg"
media_version="${MEDIA_VERSION:-${1:-main}}"
media_merge_version="${MEDIA_MERGE_VERSION:-${2:-1.11.0-rc01}}"
ffmpeg_ref="${FFMPEG_REF:-${3:-master}}"
ffmpeg_url="${FFMPEG_URL:-https://github.com/FFmpeg/FFmpeg.git}"
ffmpeg_static_mode="${FFMPEG_STATIC_MODE:-source}"
output_root="${OUTPUT_DIR:-${repo_root}/OUTPUT}"

jni_root="${media_root}/libraries/decoder_ffmpeg/src/main/jni"
jni_ffmpeg="${jni_root}/ffmpeg"
jni_libyuv="${jni_root}/libyuv"
libyuv_url="https://chromium.googlesource.com/libyuv/libyuv"

# Each entry is <pull request>:<upstream comparison branch>. Keeping the branch
# beside the PR makes the cherry-pick range obvious when this list changes.
media_prs=(
    3280:main
    3271:main
    3276:release
    3151:main
    3055:release
    3092:release
    3330:main
    3351:main
    3344:main
)

case "${ffmpeg_static_mode}" in
    source|prebuilt) ;;
    *) fail "FFMPEG_STATIC_MODE must be source or prebuilt, not '${ffmpeg_static_mode}'." ;;
esac

[[ -f "${aar_gradle_script}" ]] ||
    fail "${aar_gradle_script} is missing. Restore the Gradle build script before continuing."

ffmpeg_prepare_task="prepareFfmpegPrebuiltDependencies"
if [[ "${ffmpeg_static_mode}" == "source" ]]; then
    ffmpeg_prepare_task="prepareFfmpegSourceDependencies"
fi

git_in() {
    local working_directory="$1"
    shift
    git -c safe.directory='*' -C "${working_directory}" "$@"
}

remove_generated_ffmpeg_link() {
    if [[ -L "${jni_ffmpeg}" ]]; then
        rm -f "${jni_ffmpeg}"
        return 0
    fi

    # No existing link is the expected state on a first run. Return success
    # explicitly so `set -e` does not stop source preparation here.
    [[ -e "${jni_ffmpeg}" ]] || return 0

    # Git Bash sees a Windows junction as a directory. The batch wrapper must
    # remove it before source preparation so this script cannot erase it by
    # accident during a Windows-only prepare pass.
    if [[ "${prepare_only}" == true ]]; then
        fail "${jni_ffmpeg} still exists. The Windows wrapper must remove its junction before calling this script."
    fi
    rm -rf "${jni_ffmpeg}"
}

clean_submodule() {
    local directory="$1"
    git_in "${directory}" reset --hard
    git_in "${directory}" clean -ffdx
}

restore_submodules() {
    remove_generated_ffmpeg_link
    clean_submodule "${media_root}"
    git_in "${media_root}" checkout --detach refs/remotes/origin/main
    clean_submodule "${ffmpeg_root}"
    git_in "${ffmpeg_root}" checkout --detach refs/remotes/origin/master
}

update_ffmpeg_source() {
    [[ "${ffmpeg_ref}" =~ ^[A-Za-z0-9._/-]+$ ]] ||
        fail "Invalid FFmpeg ref: ${ffmpeg_ref}"

    printf 'Updating FFmpeg from %s at %s\n' "${ffmpeg_url}" "${ffmpeg_ref}"
    git_in "${ffmpeg_root}" reset --hard
    git_in "${ffmpeg_root}" clean -ffdx -e 'android-libs/'
    git_in "${ffmpeg_root}" remote set-url origin "${ffmpeg_url}"
    git_in "${ffmpeg_root}" config core.autocrlf false
    git_in "${ffmpeg_root}" config core.longpaths true

    local resolved_ref
    if git_in "${ffmpeg_root}" fetch --depth 1 --no-tags --prune origin \
        "+refs/heads/${ffmpeg_ref}:refs/remotes/origin/${ffmpeg_ref}" 2>/dev/null; then
        resolved_ref="refs/remotes/origin/${ffmpeg_ref}"
    elif git_in "${ffmpeg_root}" fetch --depth 1 --tags --prune origin "${ffmpeg_ref}"; then
        resolved_ref="FETCH_HEAD"
    else
        fail "Could not fetch FFmpeg ref ${ffmpeg_ref} from ${ffmpeg_url}."
    fi

    local commit
    commit="$(git_in "${ffmpeg_root}" rev-parse "${resolved_ref}^{commit}")"
    git_in "${ffmpeg_root}" checkout --detach "${commit}"
    git_in "${ffmpeg_root}" clean -ffdx -e 'android-libs/'

    printf 'FFmpeg source: %s (%s)\n' \
        "$(git_in "${ffmpeg_root}" describe --tags --always --abbrev=12)" \
        "${commit}"
}

fetch_media_refs() {
    local entry
    local pr
    local -a refspecs=(
        "+refs/heads/main:refs/remotes/origin/main"
        "+refs/heads/release:refs/remotes/origin/release"
    )

    for entry in "${media_prs[@]}"; do
        pr="${entry%%:*}"
        refspecs+=("+refs/pull/${pr}/head:refs/media-build/pr-${pr}")
    done

    echo "Fetching Media3 branches, tags, and selected pull requests"
    git_in "${media_root}" fetch origin --tags --prune "${refspecs[@]}"
}

resolve_media_ref() {
    local version="${1:-${media_version}}"
    local candidate

    if [[ -z "${version}" ]]; then
        echo "origin/main"
        return
    fi

    for candidate in "${version}" "origin/${version}" "refs/tags/${version}"; do
        if git_in "${media_root}" rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
            echo "${candidate}"
            return
        fi
    done

    # The common refs were fetched in one request. This fallback keeps support
    # for an arbitrary branch, tag, or reachable commit without fetching every
    # remote branch on every build.
    if git_in "${media_root}" fetch --no-tags origin "${version}" >/dev/null 2>&1; then
        git_in "${media_root}" rev-parse FETCH_HEAD
        return
    fi

    fail "Could not resolve Media3 ref: ${version}"
}

ensure_git_identity() {
    if ! git_in "${media_root}" config user.name >/dev/null; then
        git_in "${media_root}" config user.name "Jellyfin Media3 build"
    fi
    if ! git_in "${media_root}" config user.email >/dev/null; then
        git_in "${media_root}" config user.email "media3-build@jellyfin.invalid"
    fi
}

commit_if_changed() {
    local source_commit="$1"

    if git_in "${media_root}" diff --cached --quiet; then
        echo "Skipping already-applied commit ${source_commit}."
    else
        git_in "${media_root}" commit --reuse-message="${source_commit}"
    fi
}

merge_media_ref() {
    [[ -n "${media_merge_version}" ]] || return 0

    local merge_ref
    local -a conflicts=()
    merge_ref="$(resolve_media_ref "${media_merge_version}")"
    git_in "${media_root}" rev-parse --verify "${merge_ref}^{commit}" >/dev/null
    echo "Merging Media3 ${merge_ref}"

    if ! git_in "${media_root}" merge --no-edit "${merge_ref}"; then
        mapfile -t conflicts < <(git_in "${media_root}" diff --name-only --diff-filter=U)
        ((${#conflicts[@]} > 0)) || fail "Media3 merge failed without reported file conflicts."

        # The selected base remains authoritative for merge conflicts. Local
        # patches and chosen PRs are replayed immediately after this merge.
        echo "Keeping the selected Media3 base for merge conflicts:"
        printf '  %s\n' "${conflicts[@]}"
        git_in "${media_root}" restore --source=HEAD --staged --worktree -- "${conflicts[@]}"
        git_in "${media_root}" add -- "${conflicts[@]}"
        git_in "${media_root}" commit --no-edit
    fi
}

apply_local_patches() {
    local patch_path
    local display_path
    local -a patch_paths=("${repo_root}"/patches/*.patch)
    [[ -e "${patch_paths[0]}" ]] || fail "No patch files were found under ${repo_root}/patches."

    for patch_path in "${patch_paths[@]}"; do
        display_path="${patch_path#${repo_root}/}"
        echo "Applying ${display_path}"
        git_in "${media_root}" apply --check --ignore-space-change --ignore-whitespace "${patch_path}" ||
            fail "${display_path} does not apply cleanly to the selected Media3 source."
        git_in "${media_root}" apply --index --whitespace=nowarn \
            --ignore-space-change --ignore-whitespace "${patch_path}"
        git_in "${media_root}" commit -m "Apply ${display_path}"
    done
}

apply_selected_media_prs() {
    echo "Applying selected AndroidX Media pull requests"

    local entry
    local pr
    local branch
    local ref
    local commit
    local commit_list
    local -a conflicts=()

    for entry in "${media_prs[@]}"; do
        pr="${entry%%:*}"
        branch="${entry#*:}"
        ref="refs/media-build/pr-${pr}"

        echo "  PR ${pr}"
        if ! commit_list="$(
            git_in "${media_root}" rev-list --reverse --no-merges --cherry-pick --right-only \
                "origin/${branch}...${ref}"
        )"; then
            fail "Could not list commits for PR ${pr}."
        fi

        while IFS= read -r commit; do
            [[ -n "${commit}" ]] || continue
            if ! git_in "${media_root}" cherry-pick --no-commit "${commit}"; then
                mapfile -t conflicts < <(git_in "${media_root}" diff --name-only --diff-filter=U)
                if ((${#conflicts[@]} != 1)) || [[ "${conflicts[0]}" != "RELEASENOTES.md" ]]; then
                    fail "PR ${pr} has unresolved conflicts: ${conflicts[*]:-unknown conflict}"
                fi
                git_in "${media_root}" restore --source=HEAD --staged --worktree -- RELEASENOTES.md
                git_in "${media_root}" add -- RELEASENOTES.md
            fi
            commit_if_changed "${commit}"
        done <<<"${commit_list}"
    done
}

ensure_libyuv_source() {
    if [[ -d "${jni_libyuv}/.git" || -f "${jni_libyuv}/.git" ]]; then
        echo "Updating cached libyuv source"
        git_in "${jni_libyuv}" remote set-url origin "${libyuv_url}"
        git_in "${jni_libyuv}" fetch --depth 1 --no-tags origin main

        local current_commit
        local target_commit
        current_commit="$(git_in "${jni_libyuv}" rev-parse HEAD)"
        target_commit="$(git_in "${jni_libyuv}" rev-parse FETCH_HEAD)"
        if [[ "${current_commit}" != "${target_commit}" ]]; then
            git_in "${jni_libyuv}" reset --hard "${target_commit}"
            # Retain ABI build directories and staged archives; CMake can then
            # rebuild only files affected by the new libyuv revision.
            git_in "${jni_libyuv}" clean -ffdx -e 'build-*/' -e 'android-libs/'
        else
            echo "libyuv is already at ${current_commit}."
        fi
        return
    fi

    rm -rf "${jni_libyuv}"
    git clone --depth 1 --single-branch --branch main \
        "${libyuv_url}" \
        "${jni_libyuv}"
}

prepare_sources() {
    require_command git
    [[ -d "${repo_root}/.git" || -f "${repo_root}/.git" ]] ||
        fail "Run this script from a Git checkout."

    git_in "${repo_root}" submodule sync --recursive
    remove_generated_ffmpeg_link
    if [[ -d "${media_root}/.git" || -f "${media_root}/.git" ]]; then
        clean_submodule "${media_root}"
    fi
    if [[ -d "${ffmpeg_root}/.git" || -f "${ffmpeg_root}/.git" ]]; then
        clean_submodule "${ffmpeg_root}"
    fi
    git_in "${repo_root}" submodule update --init --recursive --force
    [[ -d "${media_root}/.git" || -f "${media_root}/.git" ]] ||
        fail "Media3 submodule is unavailable."
    [[ -d "${ffmpeg_root}/.git" || -f "${ffmpeg_root}/.git" ]] ||
        fail "FFmpeg submodule is unavailable."

    update_ffmpeg_source

    git_in "${media_root}" remote set-url origin https://github.com/androidx/media.git
    git_in "${media_root}" config core.autocrlf false
    git_in "${media_root}" config core.longpaths true
    fetch_media_refs

    local media_ref
    media_ref="$(resolve_media_ref)"
    git_in "${media_root}" rev-parse --verify "${media_ref}^{commit}" >/dev/null
    echo "Checking out Media3 ${media_ref}"
    git_in "${media_root}" checkout --detach "${media_ref}"

    ensure_git_identity
    merge_media_ref
    apply_local_patches
    apply_selected_media_prs
    ensure_libyuv_source
}

validate_prepared_sources() {
    [[ -d "${media_root}" ]] || fail "Media3 source is missing. Run without --build-only first."
    [[ -d "${ffmpeg_root}" ]] || fail "FFmpeg source is missing. Run without --build-only first."
    [[ -d "${jni_libyuv}" ]] || fail "libyuv source is missing. Run without --build-only first."
}

link_ffmpeg_source() {
    rm -rf "${jni_ffmpeg}"
    ln -s "${ffmpeg_root}" "${jni_ffmpeg}"
}

run_gradle_build() {
    if [[ "${ffmpeg_static_mode}" == "source" ]]; then
        require_command make "GNU make is required to build FFmpeg static libraries from source."
    fi

    (
        cd "${repo_root}"
        ./gradlew \
            -PffmpegStaticMode="${ffmpeg_static_mode}" \
            "${ffmpeg_prepare_task}" \
            buildMedia3Aars
    )
}

main() {
    if [[ "${restore_only}" == true ]]; then
        restore_submodules
        return
    fi

    if [[ "${build_only}" == true ]]; then
        validate_prepared_sources
    else
        prepare_sources
    fi

    if [[ "${prepare_only}" == true ]]; then
        if [[ "${build_only}" == true ]]; then
            echo "Source preparation was skipped. The Windows wrapper will create the FFmpeg junction and run Gradle."
        else
            echo "Media3 source update completed. The Windows wrapper will create the FFmpeg junction and run Gradle."
        fi
        return
    fi

    link_ffmpeg_source
    run_gradle_build
    restore_submodules
    echo "Media3 and FFmpeg AARs are under ${output_root}"
}

main
