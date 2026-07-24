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
- Builds the FFmpeg submodule as static libraries for `armeabi-v7a`, `arm64-v8a`, `x86`,
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

The build starts from `origin/main` by default, applies these selected AndroidX
Media pull requests, then applies the numbered local patches in [`patches/`](patches/):

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
- Android SDK with `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or `sdk.dir` in `local.properties`.
- At least one Android NDK installed in the SDK. The newest installed side-by-side NDK is selected automatically.
- CMake and Ninja available on `PATH` or installed as an Android SDK CMake package.
- Network access to fetch AndroidX Media refs and the current libyuv `main` branch, which is built as a static native dependency.

Clone the repository with its Media3 and FFmpeg submodules:

```bash
git clone --recurse-submodules https://github.com/thor2002ro/jellyfin-androidx-media.git
cd jellyfin-androidx-media
```

For an existing checkout:

```bash
git submodule update --init --recursive
```

### Native tool selection

The build reads an explicit NDK path from `-PandroidNdkPath`,
`ANDROID_NDK_PATH`, `ANDROID_NDK_ROOT`, `ANDROID_NDK_HOME`, or `ANDROID_NDK`.
Otherwise it
selects the newest installed NDK under `<Android SDK>/ndk`. Pin a specific
installed package with `-PandroidNdkVersion` or `ANDROID_NDK_VERSION`.

CMake and Ninja can be overridden with `-PcmakePath`/`CMAKE` and
`-PninjaPath`/`NINJA`. Without overrides, the build checks `PATH` and then the
installed Android SDK CMake packages, choosing the newest package available.

## Build on Windows

Install Git for Windows, Java 17, the Android SDK with an NDK, and CMake with
Ninja, then run:

```bat
update-repo.bat
```

To select another Media3 ref:

```bat
update-repo.bat <Media3-ref>
```

The default output is:

```text
OUTPUT/media3-*-release.aar
OUTPUT/media3-ffmpeg-decoder-release.aar
OUTPUT/android-libs/<ABI>/libavcodec.a
OUTPUT/android-libs/<ABI>/libavutil.a
OUTPUT/android-libs/<ABI>/libswresample.a
OUTPUT/android-libs/<ABI>/libswscale.a
```

## Build on Linux

Install an Android NDK plus CMake and Ninja, then set `ANDROID_HOME`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
./build.sh
```

To select another Media3 ref or mode:

```bash
./build.sh <Media3-ref>
./build.sh media3 <Media3-ref>
./build.sh ffmpeg <Media3-ref>
```

The same `OUTPUT` files are written as on Windows:

```text
OUTPUT/media3-*-release.aar
OUTPUT/media3-ffmpeg-decoder-release.aar
OUTPUT/android-libs/<ABI>/libavcodec.a
OUTPUT/android-libs/<ABI>/libavutil.a
OUTPUT/android-libs/<ABI>/libswresample.a
OUTPUT/android-libs/<ABI>/libswscale.a
```

The repository's CI-equivalent Maven build is:

```bash
ANDROIDX_MEDIA_ROOT="$PWD/media" \
  ./gradlew :media3-ffmpeg-decoder:publishToMavenLocal
```

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
