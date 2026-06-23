#!/bin/bash

# Ensure NDK is available
export ANDROID_NDK_PATH=$ANDROID_HOME/ndk/26.1.10909125

[[ ! -d "$ANDROID_NDK_PATH" ]] && echo "No NDK found, quitting…" && exit 1

# Setup environment
export ANDROIDX_MEDIA_ROOT="${PWD}/media"
export FFMPEG_MOD_PATH="${ANDROIDX_MEDIA_ROOT}/libraries/decoder_ffmpeg/src/main"
export FFMPEG_PATH="${PWD}/ffmpeg"
export ENABLED_DECODERS=(
    flac alac pcm_mulaw pcm_alaw pcm_s16le pcm_f32le adpcm_ima_wav adpcm_ms
    mp1 mp2 mp3 aac ac3 eac3 dca mlp truehd
    vorbis opus amrnb amrwb wavpack ape speex gsm gsm_ms
    mpeg1video mpeg2video flv h263 vp6 vp6f h264 hevc
    msmpeg4v1 msmpeg4v2 msmpeg4v3 mpeg4 wmv1 wmv2 wmv3 vc1
)

# Create softlink to ffmpeg
ln -sf "${FFMPEG_PATH}" "${FFMPEG_MOD_PATH}/jni/ffmpeg"

# Start build
cd "${FFMPEG_MOD_PATH}/jni"
./build_ffmpeg.sh "${FFMPEG_MOD_PATH}" "${ANDROID_NDK_PATH}" "linux-x86_64" 23 "${ENABLED_DECODERS[@]}"
