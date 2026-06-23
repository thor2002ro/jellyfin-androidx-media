param(
    [string] $AndroidHome = $env:ANDROID_HOME,
    [string] $NdkVersion = $env:ANDROID_NDK_VERSION,
    [int] $AndroidApi = 23
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($AndroidHome)) {
    $AndroidHome = $env:ANDROID_SDK_ROOT
}

if ([string]::IsNullOrWhiteSpace($AndroidHome)) {
    $AndroidHome = Join-Path $env:LOCALAPPDATA "Android\Sdk"
}

if ([string]::IsNullOrWhiteSpace($NdkVersion)) {
    $NdkVersion = "26.1.10909125"
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDir = Join-Path $repoRoot "build"
$ffmpegExportDir = Join-Path $buildDir "ffmpeg-src-lf"
$scriptBuildDir = Join-Path $buildDir "static-libs"
$tempBuildScript = Join-Path $scriptBuildDir "build_ffmpeg_8_1.sh"
$tempSetupScript = Join-Path $scriptBuildDir "setup_static_libs.sh"
$jniFfmpegPath = Join-Path $repoRoot "media\libraries\decoder_ffmpeg\src\main\jni\ffmpeg"
$upstreamBuildScript = Join-Path $repoRoot "media\libraries\decoder_ffmpeg\src\main\jni\build_ffmpeg.sh"
$ndkPath = Join-Path $AndroidHome "ndk\$NdkVersion"
$winToolchainBin = Join-Path $ndkPath "toolchains\llvm\prebuilt\windows-x86_64\bin"

$enabledDecoders = @(
    "flac", "alac", "pcm_mulaw", "pcm_alaw", "pcm_s16le", "pcm_f32le", "adpcm_ima_wav", "adpcm_ms",
    "mp1", "mp2", "mp3", "aac", "ac3", "eac3", "dca", "mlp", "truehd",
    "vorbis", "opus", "amrnb", "amrwb", "wavpack", "ape", "speex", "gsm", "gsm_ms",
    "mpeg1video", "mpeg2video", "flv", "h263", "vp6", "vp6f", "h264", "hevc",
    "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "mpeg4", "wmv1", "wmv2", "wmv3", "vc1"
)

function Resolve-RequiredPath([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description was not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-ChildPath([string] $Child, [string] $Parent) {
    $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')

    if (-not $childFull.StartsWith($parentFull + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside $parentFull`: $childFull"
    }
}

function Remove-LinkOrGeneratedPath([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

    if ($isReparsePoint) {
        if ($item.PSIsContainer) {
            [System.IO.Directory]::Delete($item.FullName)
        } else {
            Remove-Item -LiteralPath $item.FullName -Force
        }
        return
    }

    throw "Refusing to remove non-link path: $Path"
}

function Convert-ToWslPath([string] $Path) {
    $wslInputPath = $Path.Replace('\', '/')
    $result = & wsl.exe wslpath -a $wslInputPath
    if ($LASTEXITCODE -ne 0) {
        throw "wslpath failed for $Path"
    }

    return ($result -join "").Trim()
}

function Quote-Bash([string] $Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}

Resolve-RequiredPath $repoRoot "Repository root" | Out-Null
Resolve-RequiredPath $upstreamBuildScript "Upstream FFmpeg build script" | Out-Null
Resolve-RequiredPath $ndkPath "Android NDK $NdkVersion" | Out-Null
Resolve-RequiredPath $winToolchainBin "Windows NDK LLVM toolchain" | Out-Null

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found. This script needs WSL because FFmpeg configure is a shell script."
}

New-Item -ItemType Directory -Force -Path $buildDir, $scriptBuildDir | Out-Null
Assert-ChildPath $ffmpegExportDir $buildDir

if (Test-Path -LiteralPath $ffmpegExportDir) {
    Remove-Item -LiteralPath $ffmpegExportDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $ffmpegExportDir | Out-Null

$wslRepoRoot = Convert-ToWslPath $repoRoot
$wslFfmpegExportDir = Convert-ToWslPath $ffmpegExportDir
$wslWinToolchainBin = Convert-ToWslPath $winToolchainBin
$wslTempBuildScript = Convert-ToWslPath $tempBuildScript
$wslTempSetupScript = Convert-ToWslPath $tempSetupScript
$wslModulePath = "$wslRepoRoot/media/libraries/decoder_ffmpeg/src/main"
$wslWrapNdk = "/tmp/jellyfin-android-ndk-winwrap/ndk/$NdkVersion"
$wslWrapBin = "$wslWrapNdk/toolchains/llvm/prebuilt/linux-x86_64/bin"

Write-Host "Exporting clean FFmpeg source to $ffmpegExportDir"
$archiveCommand = "set -euo pipefail; git -C $(Quote-Bash "$wslRepoRoot/ffmpeg") archive HEAD | tar -x -C $(Quote-Bash $wslFfmpegExportDir)"
& wsl.exe bash -lc $archiveCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to export FFmpeg source"
}

Write-Host "Preparing FFmpeg 8.1 build script"
$buildScriptText = [System.IO.File]::ReadAllText($upstreamBuildScript)
$buildScriptText = $buildScriptText -replace "`r`n", "`n"
$buildScriptText = $buildScriptText -replace "`r", "`n"
$buildScriptLines = $buildScriptText -split "`n" | Where-Object { $_ -notmatch "--disable-postproc" }
$buildScriptText = ($buildScriptLines -join "`n") + "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tempBuildScript, $buildScriptText, $utf8NoBom)

Write-Host "Pointing decoder_ffmpeg JNI source at the clean FFmpeg export"
Remove-LinkOrGeneratedPath $jniFfmpegPath
New-Item -ItemType Junction -Path $jniFfmpegPath -Target $ffmpegExportDir | Out-Null

$decoderArgs = ($enabledDecoders | ForEach-Object { Quote-Bash $_ }) -join " "
$setupAndBuildCommand = @"
set -euo pipefail
command -v make >/dev/null
command -v git >/dev/null
command -v tar >/dev/null
rm -rf $(Quote-Bash $wslWrapNdk)
mkdir -p $(Quote-Bash $wslWrapBin)
for tool in $(Quote-Bash $wslWinToolchainBin)/*; do
  name="`$(basename "`$tool")"
  ln -s "`$tool" $(Quote-Bash $wslWrapBin)/"`$name"
  case "`$name" in
    *.exe) ln -s "`$tool" $(Quote-Bash $wslWrapBin)/"`${name%.exe}" ;;
  esac
done
for triple in armv7a-linux-androideabi aarch64-linux-android i686-linux-android x86_64-linux-android; do
  ln -sf "`${triple}$AndroidApi-clang" $(Quote-Bash $wslWrapBin)/"`${triple}$AndroidApi-gcc"
  ln -sf "`${triple}$AndroidApi-clang++" $(Quote-Bash $wslWrapBin)/"`${triple}$AndroidApi-g++"
done
mkdir -p $(Quote-Bash "$wslFfmpegExportDir/ffbuild-tmp")
cd $(Quote-Bash "$wslRepoRoot/media/libraries/decoder_ffmpeg/src/main/jni")
TMPDIR=ffbuild-tmp bash $(Quote-Bash $wslTempBuildScript) $(Quote-Bash $wslModulePath) $(Quote-Bash $wslWrapNdk) linux-x86_64 $AndroidApi $decoderArgs
"@

Write-Host "Building FFmpeg static libraries"
[System.IO.File]::WriteAllText($tempSetupScript, $setupAndBuildCommand + "`n", $utf8NoBom)
& wsl.exe bash $wslTempSetupScript
if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg static library build failed"
}

$expectedAbis = @("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
$expectedLibs = @("libavcodec.a", "libavutil.a", "libswresample.a")

foreach ($abi in $expectedAbis) {
    foreach ($lib in $expectedLibs) {
        $libPath = Join-Path $ffmpegExportDir "android-libs\$abi\$lib"
        if (-not (Test-Path -LiteralPath $libPath)) {
            throw "Expected static library was not created: $libPath"
        }
    }
}

Write-Host "Updated FFmpeg static libraries:"
foreach ($abi in $expectedAbis) {
    Write-Host "  $abi"
}
Write-Host "Static libraries are under $ffmpegExportDir\android-libs"
