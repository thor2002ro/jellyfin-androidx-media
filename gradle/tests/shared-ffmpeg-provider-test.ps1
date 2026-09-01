$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildRoot = Join-Path $repositoryRoot 'build'
$testRoot = Join-Path $buildRoot ('sfp-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$resolvedBuildRoot = [System.IO.Path]::GetFullPath($buildRoot) + [System.IO.Path]::DirectorySeparatorChar
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedBuildRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe test directory: $resolvedTestRoot"
}

function Invoke-ProviderGradle {
    param([string]$Task, [string]$PropertyValue)

    $arguments = @('-q', $Task)
    if ($PropertyValue) {
        $arguments += "-PjellyfinSharedFfmpegAar=$PropertyValue"
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & (Join-Path $repositoryRoot 'gradlew.bat') @arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $fixture = Join-Path $testRoot 'fixture'
    New-Item -ItemType Directory -Path (Join-Path $fixture 'META-INF') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'prefab') -Force | Out-Null

    $commit = '0123456789abcdef0123456789abcdef01234567'
    $decoders = @(
        'aac', 'mp3', 'mp1', 'mp2', 'ac3', 'eac3', 'truehd', 'dca', 'vorbis', 'opus',
        'amrnb', 'amrwb', 'flac', 'alac', 'pcm_mulaw', 'pcm_alaw', 'gsm_ms',
        'h264', 'hevc', 'av1', 'vp8', 'vp9', 'flv', 'mpeg1video', 'mpeg2video',
        'mpeg4', 'msmpeg4v2', 'msmpeg4v3', 'h263', 'vc1', 'wmv1', 'wmv2', 'wmv3'
    ) -join ','
    @"
group=io.github.abdallahmehiz
artifact=mpv-ffmpeg-android
version=9.2-thor.0123456789ab
ffmpeg_version=9.2
ffmpeg_commit=$commit
ndk_version=29.0.14206865
abis=armeabi-v7a,arm64-v8a,x86,x86_64
optimization=O3,thin-lto,armv7-neon,armv7-thumb,arm64-neon
decoders=$decoders
"@ | Set-Content -NoNewline (Join-Path $fixture 'META-INF\mpv-ffmpeg-android.properties')
    '{"schema_version":2,"name":"mpv_ffmpeg_android","version":"8.1.0","dependencies":[]}' |
        Set-Content -NoNewline (Join-Path $fixture 'prefab\prefab.json')

    $libraries = @('avcodec', 'avdevice', 'avfilter', 'avformat', 'avutil', 'swresample', 'swscale')
    foreach ($library in $libraries) {
        $moduleRoot = Join-Path $fixture "prefab\modules\$library"
        New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
        '{}' | Set-Content -NoNewline (Join-Path $moduleRoot 'module.json')
    }
    foreach ($abi in @('armeabi-v7a', 'arm64-v8a', 'x86', 'x86_64')) {
        $jniRoot = Join-Path $fixture "jni\$abi"
        $codecHeaders = Join-Path $fixture "headers\$abi\libavcodec"
        $utilHeaders = Join-Path $fixture "headers\$abi\libavutil"
        New-Item -ItemType Directory -Path $jniRoot, $codecHeaders, $utilHeaders -Force | Out-Null
        '#define LIBAVCODEC_VERSION_MAJOR 62' | Set-Content (Join-Path $codecHeaders 'version_major.h')
        '#define AV_HAVE_BIGENDIAN 0' | Set-Content (Join-Path $utilHeaders 'avconfig.h')
        foreach ($library in $libraries) {
            "$abi-$library" | Set-Content (Join-Path $jniRoot "lib$library.so")
        }
    }

    $providerVersion = '9.2-thor.0123456789ab'
    $providerDirectory = Join-Path $testRoot "maven\io\github\abdallahmehiz\mpv-ffmpeg-android\$providerVersion"
    New-Item -ItemType Directory -Path $providerDirectory -Force | Out-Null
    $providerAar = Join-Path $providerDirectory "mpv-ffmpeg-android-$providerVersion.aar"
    & jar cf $providerAar -C $fixture .
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create provider AAR fixture."
    }
    @"
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.github.abdallahmehiz</groupId>
  <artifactId>mpv-ffmpeg-android</artifactId>
  <version>$providerVersion</version>
  <packaging>aar</packaging>
</project>
"@ | Set-Content -NoNewline (Join-Path $providerDirectory "mpv-ffmpeg-android-$providerVersion.pom")
    $relativeAar = $providerAar.Substring($repositoryRoot.Length).TrimStart('\')

    $static = Invoke-ProviderGradle 'verifySharedFfmpegProvider' ''
    if ($static.ExitCode -ne 0 -or $static.Output -notmatch 'static FFmpeg mode selected') {
        throw "Absent provider did not select static FFmpeg mode.`n$($static.Output)"
    }

    $valid = Invoke-ProviderGradle 'stageSharedFfmpegProvider' $relativeAar
    if ($valid.ExitCode -ne 0) {
        throw "Valid relative provider was rejected.`n$($valid.Output)"
    }
    $stagedCodec = Join-Path $repositoryRoot 'build\shared-ffmpeg-provider\jni\arm64-v8a\libavcodec.so'
    if (-not (Test-Path $stagedCodec -PathType Leaf)) {
        throw "Valid provider was not staged: $stagedCodec"
    }

    $mediaArguments = @(
        ':lib-decoder-ffmpeg:dependencies',
        '--configuration',
        'releaseRuntimeClasspath',
        ':lib-decoder-ffmpeg:generatePomFileForReleasePublication',
        "-PjellyfinSharedFfmpegMavenRepo=$(Join-Path $testRoot 'maven')",
        '-PjellyfinSharedFfmpegGroup=io.github.abdallahmehiz',
        '-PjellyfinSharedFfmpegArtifact=mpv-ffmpeg-android',
        "-PjellyfinSharedFfmpegVersion=$providerVersion",
        '--rerun-tasks'
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location (Join-Path $repositoryRoot 'media')
    try {
        $mediaOutput = & '.\gradlew.bat' @mediaArguments 2>&1 | Out-String
        $mediaExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($mediaExitCode -ne 0) {
        throw "Media3 provider metadata generation failed.`n$mediaOutput"
    }
    if ($mediaOutput -notmatch 'io.github.abdallahmehiz:mpv-ffmpeg-android') {
        throw "Provider dependency is missing from the Media3 runtime dependency graph."
    }
    $publicationRoot = Join-Path $repositoryRoot 'media\libraries\decoder_ffmpeg\buildout\publications\release'
    foreach ($metadataFile in @('pom-default.xml')) {
        $metadataPath = Join-Path $publicationRoot $metadataFile
        if (-not (Test-Path $metadataPath -PathType Leaf) -or
            (Get-Content $metadataPath -Raw) -notmatch 'mpv-ffmpeg-android') {
            throw "Provider dependency is missing from Media3 publication metadata: $metadataPath"
        }
    }

    $absolute = Invoke-ProviderGradle 'verifySharedFfmpegProvider' $providerAar
    if ($absolute.ExitCode -eq 0 -or $absolute.Output -notmatch 'must be relative') {
        throw "Absolute provider path was not rejected.`n$($absolute.Output)"
    }

    $missing = Invoke-ProviderGradle 'verifySharedFfmpegProvider' 'build\missing-provider.aar'
    if ($missing.ExitCode -eq 0 -or $missing.Output -notmatch 'does not exist') {
        throw "Missing relative provider was not rejected.`n$($missing.Output)"
    }

    Write-Output 'Media3 shared FFmpeg provider contracts passed'
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
