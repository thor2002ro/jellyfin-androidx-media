# Jellyfin AndroidX Media - FFmpeg video fork

This repository is a fork of
[jellyfin/jellyfin-androidx-media](https://github.com/jellyfin/jellyfin-androidx-media).
It builds a custom AndroidX Media3 FFmpeg decoder for Jellyfin Android TV.
The changes described below are maintained by this fork and should not be
treated as an official Jellyfin or AndroidX Media release.

## Fork changes

### FFmpeg video decoding

- Adds software decoding for MPEG-1, MPEG-2, H.263, VP8, VP9, H.264, HEVC,
  Dolby Vision, MPEG-4/DivX, MSMPEG4v2, MSMPEG4v3, and VC-1 streams.
- Adds Microsoft GSM audio mapping and keeps the FFmpeg build limited to the
  codecs advertised by the decoder.
- Enables FFmpeg frame-threaded video decoding.
- Builds FFmpeg 8.1 as static libraries for `armeabi-v7a`, `arm64-v8a`, `x86`,
  and `x86_64`.

### Native surface rendering

- Retains decoded `AVFrame` instances in `VideoDecoderOutputBuffer` and releases
  them when output buffers are dropped or recycled.
- Defers conversion, rotation, and deinterlacing until a frame is rendered.
- Converts and renders directly into Android `ANativeWindow` YV12 memory,
  including the required Y, V, U plane order and chroma stride handling.
- Supports bob deinterlacing without a Java YUV staging-buffer copy.
- Reuses packet, scratch-frame, and independent decode/render `SwsContext`
  allocations.
- Handles surface replacement, transient surface errors, decoder draining, and
  complete native context cleanup.
- Rate-limits repeated invalid-data and surface error logging.

### Media3 fixes

The build starts from `origin/main` by default and applies the FFmpeg video
renderer commit series from [AndroidX Media PR 1591](https://github.com/androidx/media/pull/1591),
the local [`ffmpeg-video-codecs.patch`](patches/ffmpeg-video-codecs.patch), and
these selected AndroidX Media pull requests:

- [PR 3280](https://github.com/androidx/media/pull/3280): Dolby Vision in HLS/TS.
- [PR 3271](https://github.com/androidx/media/pull/3271): PCM and silence-skipping
  math corrections.
- [PR 3276](https://github.com/androidx/media/pull/3276): E-AC-3 sample-count
  parsing.
- [PR 3151](https://github.com/androidx/media/pull/3151): subtitle cue stacking.
- [PR 3055](https://github.com/androidx/media/pull/3055): `SurfaceView` zoom
  overflow.
- [PR 3092](https://github.com/androidx/media/pull/3092): HLS/TS I-frame test
  coverage.
- [PR 3330](https://github.com/androidx/media/pull/3330): 14-bit DTS frame-size
  calculation.

The Media3 base is resolved at build time. Pass a branch, tag, or other valid
Media3 ref when a build must use something other than `origin/main`.

## Build requirements

- Git with submodule support.
- Java 17.
- Android SDK with `ANDROID_HOME` or `ANDROID_SDK_ROOT` set.
- Android NDK `26.1.10909125`.
- CMake `3.31.1`.
- Network access to fetch AndroidX Media refs and libyuv.

Clone the repository with its Media3 and FFmpeg submodules:

```bash
git clone --recurse-submodules https://github.com/thor2002ro/jellyfin-androidx-media.git
cd jellyfin-androidx-media
```

For an existing checkout:

```bash
git submodule update --init --recursive
```

## Build on Windows

Windows builds additionally require PowerShell and WSL with `bash`, `make`,
`git`, and `tar`. The wrapper performs the complete build:

```bat
update-static-libs.bat
```

To build another Media3 branch, tag, or ref:

```bat
update-static-libs.bat <Media3-ref>
```

PowerShell parameters can be passed through the wrapper:

```bat
update-static-libs.bat <Media3-ref> -AndroidApi 23 -OutputDir ".\OUTPUT-custom"
```

The default output is:

```text
OUTPUT/media3-ffmpeg-decoder-latest-SNAPSHOT.aar
OUTPUT/android-libs/<ABI>/libavcodec.a
OUTPUT/android-libs/<ABI>/libavutil.a
OUTPUT/android-libs/<ABI>/libswresample.a
OUTPUT/android-libs/<ABI>/libswscale.a
```

The generated Media3 source tree is recreated under
`%TEMP%\jellyfin-androidx-media-pr-stack` on every build.

## Build on Linux

Install NDK `26.1.10909125` and CMake `3.31.1`, then set `ANDROID_HOME`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
./build.sh
```

To select another Media3 ref:

```bash
./build.sh <Media3-ref>
```

Build the release AAR from the generated Media3 source tree:

```bash
MEDIA_BUILD_ROOT="${TMPDIR:-/tmp}/jellyfin-androidx-media-pr-stack"
(
  cd "$MEDIA_BUILD_ROOT"
  ./gradlew :lib-decoder-ffmpeg:assembleRelease
)
```

The AAR is written to:

```text
$MEDIA_BUILD_ROOT/libraries/decoder_ffmpeg/buildout/outputs/aar/lib-decoder-ffmpeg-release.aar
```

The repository's CI-equivalent Maven build is:

```bash
ANDROIDX_MEDIA_ROOT="$MEDIA_BUILD_ROOT" \
  ./gradlew :media3-ffmpeg-decoder:publishToMavenLocal
```

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
