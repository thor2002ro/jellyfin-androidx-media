param(
    [string] $AndroidHome = $env:ANDROID_HOME,
    [string] $NdkVersion = $env:ANDROID_NDK_VERSION,
    [int] $AndroidApi = 23,
    [string] $MediaVersion = $env:MEDIA_VERSION,
    [string] $OutputDir = ""
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
$mediaBuildRoot = Join-Path $repoRoot "media"
$ffmpegRoot = Join-Path $repoRoot "ffmpeg"
$scriptBuildDir = Join-Path $buildDir "static-libs"
$outputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Join-Path $repoRoot "OUTPUT"
} else {
    [System.IO.Path]::GetFullPath($OutputDir)
}
$outputAndroidLibsDir = Join-Path $outputDir "android-libs"
$tempBuildScript = Join-Path $scriptBuildDir "build_ffmpeg_8_1.sh"
$tempSetupScript = Join-Path $scriptBuildDir "setup_static_libs.sh"
$jniRoot = Join-Path $mediaBuildRoot "libraries\decoder_ffmpeg\src\main\jni"
$jniFfmpegPath = Join-Path $jniRoot "ffmpeg"
$jniLibyuvPath = Join-Path $jniRoot "libyuv"
$upstreamBuildScript = Join-Path $jniRoot "build_ffmpeg.sh"
$ffmpegVideoPatch = Join-Path $repoRoot "patches\ffmpeg-video-codecs.patch"
$ndkPath = Join-Path $AndroidHome "ndk\$NdkVersion"
$winToolchainBin = Join-Path $ndkPath "toolchains\llvm\prebuilt\windows-x86_64\bin"

$enabledDecoders = @(
    "flac", "alac", "pcm_mulaw", "pcm_alaw", "mp3", "aac", "ac3", "eac3", "dca", "truehd",
    "vorbis", "opus", "amrnb", "amrwb", "gsm_ms",
    "mpeg1video", "mpeg2video", "h263", "vp8", "vp9", "h264", "hevc",
    "msmpeg4v2", "msmpeg4v3", "mpeg4", "vc1"
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

function Convert-TextFileToLf([string] $Path) {
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Contains("`r")) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, (($text -replace "`r`n", "`n") -replace "`r", "`n"), $utf8NoBom)
    }
}

function Convert-GitTextFilesToLf([string] $Repository) {
    $files = @(& git.exe -C $Repository grep -Il ".")
    if ($LASTEXITCODE -gt 1) {
        throw "Failed to list text files in $Repository"
    }

    foreach ($file in $files) {
        Convert-TextFileToLf (Join-Path $Repository $file)
    }
}

function Invoke-Git([string] $WorkingDirectory, [string[]] $Arguments) {
    & git.exe -C $WorkingDirectory @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git failed in $WorkingDirectory`: git $($Arguments -join ' ')"
    }
}

function Get-RecordedSubmoduleCommit([string] $Path) {
    $entry = & git.exe -C $repoRoot ls-files --stage -- $Path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($entry)) {
        throw "Failed to read recorded submodule commit for $Path"
    }

    $parts = ($entry -join " ") -split "\s+"
    if ($parts.Count -lt 2 -or $parts[0] -ne "160000") {
        throw "Path is not a recorded submodule: $Path"
    }

    return $parts[1]
}

function Reset-SubmoduleToRecordedCommit([string] $Path, [string] $WorkingDirectory) {
    $commit = Get-RecordedSubmoduleCommit $Path
    Invoke-Git $WorkingDirectory @("checkout", "--detach", $commit)
    Invoke-Git $WorkingDirectory @("reset", "--hard")
    Invoke-Git $WorkingDirectory @("clean", "-ffdx")
}

function Initialize-MediaPrStack {
    Resolve-RequiredPath $mediaBuildRoot "Media3 submodule" | Out-Null
    Resolve-RequiredPath $ffmpegRoot "FFmpeg submodule" | Out-Null

    Reset-BuildSubmodulesToRecordedCommits "before build"
    Invoke-Git $mediaBuildRoot @("config", "core.autocrlf", "false")
    Invoke-Git $ffmpegRoot @("config", "core.autocrlf", "false")
    Convert-GitTextFilesToLf $ffmpegRoot

    Invoke-Git $mediaBuildRoot @("config", "core.longpaths", "true")
    Invoke-Git $mediaBuildRoot @("remote", "set-url", "origin", "https://github.com/androidx/media.git")
    Invoke-Git $mediaBuildRoot @("fetch", "origin", "--tags", "main", "release")
    $mediaVersion = $MediaVersion
    if ([string]::IsNullOrWhiteSpace($mediaVersion)) {
        $mediaVersion = "origin/main"
    } else {
        & git.exe -C $mediaBuildRoot rev-parse --verify --quiet $mediaVersion | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git.exe -C $mediaBuildRoot rev-parse --verify --quiet "origin/$mediaVersion" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $mediaVersion = "origin/$mediaVersion"
            } else {
                $mediaVersion = "refs/tags/$mediaVersion"
            }
        }
    }
    Invoke-Git $mediaBuildRoot @("rev-parse", "--verify", $mediaVersion)
    Write-Host "Building Media3 $mediaVersion"
    Invoke-Git $mediaBuildRoot @("checkout", "--detach", $mediaVersion)
    Invoke-Git $mediaBuildRoot @("fetch", "origin", "refs/pull/1591/head")

    $ffmpegVideoCommits = @(
        "3e4245768dc3cd4490944e5a3c94a528302ffb46", "bb281936ca6b945d8f646fef49b62a63eb92f6a3",
        "9a4a2820b9bf6063bc6ebc064045f1f191af2d27", "24cc94504f5aa59bf0e8310d01c9d10055e5afe8",
        "53bc7dfe288635b63208dd805f19e3943684bb92", "00ef1b5dddb2e5b1141de6ca976b978108328319",
        "57346bbf36a7456e99008298cf55ce16011401db"
    )
    foreach ($commit in $ffmpegVideoCommits) {
        & git.exe -C $mediaBuildRoot cherry-pick --no-commit $commit
        if ($LASTEXITCODE -ne 0) {
            if ($commit -ne $ffmpegVideoCommits[0]) { throw "FFmpeg video commit conflicts: $commit" }
            Invoke-Git $mediaBuildRoot @("checkout", "--ours", "--", "libraries/decoder_ffmpeg/README.md")
            Invoke-Git $mediaBuildRoot @("rm", "--", "libraries/decoder_ffmpeg/build.gradle")
            Invoke-Git $mediaBuildRoot @("checkout", "--theirs", "--", "libraries/decoder_ffmpeg/src/main/java/androidx/media3/decoder/ffmpeg/ExperimentalFfmpegVideoRenderer.java")
            Invoke-Git $mediaBuildRoot @("add", "libraries/decoder_ffmpeg")
        }
        Invoke-Git $mediaBuildRoot @("commit", "--reuse-message=$commit")
    }

    $pullRequests = @(
        @{ Number = 3280; Branch = "main" },
        @{ Number = 3271; Branch = "main" },
        @{ Number = 3276; Branch = "release" },
        @{ Number = 3151; Branch = "main" },
        @{ Number = 3055; Branch = "release" },
        @{ Number = 3092; Branch = "release" },
        @{ Number = 3330; Branch = "main" }
    )

    foreach ($pullRequest in $pullRequests) {
        $number = $pullRequest.Number
        $ref = "refs/media-build/pr-$number-head"
        Invoke-Git $mediaBuildRoot @("fetch", "origin", "refs/pull/$number/head`:$ref")
        $commits = @(& git.exe -C $mediaBuildRoot rev-list --reverse --no-merges --cherry-pick --right-only "origin/$($pullRequest.Branch)...$ref")
        if ($LASTEXITCODE -ne 0) { throw "Failed to list commits for PR $number" }

        foreach ($commit in $commits) {
            & git.exe -C $mediaBuildRoot cherry-pick --no-commit $commit
            if ($LASTEXITCODE -ne 0) {
                $conflicts = @(& git.exe -C $mediaBuildRoot diff --name-only --diff-filter=U)
                if ($conflicts.Count -ne 1 -or $conflicts[0] -ne "RELEASENOTES.md") {
                    throw "PR $number conflicts in: $($conflicts -join ', ')"
                }
                Invoke-Git $mediaBuildRoot @("checkout", "--ours", "--", "RELEASENOTES.md")
                Invoke-Git $mediaBuildRoot @("add", "RELEASENOTES.md")
            }
            Invoke-Git $mediaBuildRoot @("commit", "--reuse-message=$commit")
        }
    }

    Invoke-Git $mediaBuildRoot @("apply", $ffmpegVideoPatch)
}

function Reset-BuildSubmodulesToRecordedCommits([string] $Reason) {
    Write-Host "Resetting media and ffmpeg submodules to recorded commits $Reason"
    Remove-LinkOrGeneratedPath $jniFfmpegPath
    if (Test-Path -LiteralPath $jniLibyuvPath) {
        Assert-ChildPath $jniLibyuvPath $mediaBuildRoot
        Remove-Item -LiteralPath $jniLibyuvPath -Recurse -Force
    }
    Reset-SubmoduleToRecordedCommit "media" $mediaBuildRoot
    Reset-SubmoduleToRecordedCommit "ffmpeg" $ffmpegRoot
}

function Reset-BuildSubmodulesAfterSuccess {
    Reset-BuildSubmodulesToRecordedCommits "after successful build"
}

Resolve-RequiredPath $repoRoot "Repository root" | Out-Null
Write-Host "Using Media3 submodule: $mediaBuildRoot"
Initialize-MediaPrStack
& git.exe clone --depth 1 --branch main https://chromium.googlesource.com/libyuv/libyuv $jniLibyuvPath
if ($LASTEXITCODE -ne 0) { throw "Failed to clone libyuv" }
Resolve-RequiredPath $upstreamBuildScript "Upstream FFmpeg build script" | Out-Null
Resolve-RequiredPath $ndkPath "Android NDK $NdkVersion" | Out-Null
Resolve-RequiredPath $winToolchainBin "Windows NDK LLVM toolchain" | Out-Null

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe was not found. This script needs WSL because FFmpeg configure is a shell script."
}

New-Item -ItemType Directory -Force -Path $buildDir, $scriptBuildDir | Out-Null
Assert-ChildPath $outputDir $repoRoot
Assert-ChildPath $outputAndroidLibsDir $outputDir

if (Test-Path -LiteralPath $outputAndroidLibsDir) {
    Remove-Item -LiteralPath $outputAndroidLibsDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$wslMediaBuildRoot = Convert-ToWslPath $mediaBuildRoot
$wslFfmpegRoot = Convert-ToWslPath $ffmpegRoot
$wslWinToolchainBin = Convert-ToWslPath $winToolchainBin
$wslTempBuildScript = Convert-ToWslPath $tempBuildScript
$wslTempSetupScript = Convert-ToWslPath $tempSetupScript
$wslModulePath = "$wslMediaBuildRoot/libraries/decoder_ffmpeg/src/main"
$wslWrapNdk = "/tmp/jellyfin-android-ndk-winwrap/ndk/$NdkVersion"
$wslWrapBin = "$wslWrapNdk/toolchains/llvm/prebuilt/linux-x86_64/bin"

Write-Host "Preparing FFmpeg build script"
$buildScriptText = [System.IO.File]::ReadAllText($upstreamBuildScript)
$buildScriptText = $buildScriptText -replace "`r`n", "`n"
$buildScriptText = $buildScriptText -replace "`r", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tempBuildScript, $buildScriptText, $utf8NoBom)

Write-Host "Pointing decoder_ffmpeg JNI source at the FFmpeg submodule"
Remove-LinkOrGeneratedPath $jniFfmpegPath
New-Item -ItemType Junction -Path $jniFfmpegPath -Target $ffmpegRoot | Out-Null

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
mkdir -p $(Quote-Bash "$wslFfmpegRoot/ffbuild-tmp")
cd $(Quote-Bash "$wslMediaBuildRoot/libraries/decoder_ffmpeg/src/main/jni")
TMPDIR=ffbuild-tmp bash $(Quote-Bash $wslTempBuildScript) $(Quote-Bash $wslModulePath) $(Quote-Bash $wslWrapNdk) linux-x86_64 $AndroidApi $decoderArgs
"@

Write-Host "Building FFmpeg static libraries"
$setupAndBuildCommand = ($setupAndBuildCommand -replace "`r`n", "`n") -replace "`r", "`n"
[System.IO.File]::WriteAllText($tempSetupScript, $setupAndBuildCommand + "`n", $utf8NoBom)
& wsl.exe bash $wslTempSetupScript
if ($LASTEXITCODE -ne 0) {
    throw "FFmpeg static library build failed"
}

$expectedAbis = @("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
$expectedLibs = @("libavcodec.a", "libavutil.a", "libswresample.a", "libswscale.a")

foreach ($abi in $expectedAbis) {
    foreach ($lib in $expectedLibs) {
        $libPath = Join-Path $ffmpegRoot "android-libs\$abi\$lib"
        if (-not (Test-Path -LiteralPath $libPath)) {
            throw "Expected static library was not created: $libPath"
        }
    }
}

Write-Host "Copying static libraries to $outputAndroidLibsDir"
Copy-Item -LiteralPath (Join-Path $ffmpegRoot "android-libs") -Destination $outputDir -Recurse

foreach ($abi in $expectedAbis) {
    foreach ($lib in $expectedLibs) {
        $libPath = Join-Path $outputAndroidLibsDir "$abi\$lib"
        if (-not (Test-Path -LiteralPath $libPath)) {
            throw "Expected output static library was not copied: $libPath"
        }
    }
}

Write-Host "Updated FFmpeg static libraries:"
foreach ($abi in $expectedAbis) {
    Write-Host "  $abi"
}
Write-Host "Static libraries are under $outputAndroidLibsDir"

$env:ANDROIDX_MEDIA_ROOT = $mediaBuildRoot
$env:ANDROID_HOME = $AndroidHome
Write-Host "Building decoder release AAR"
Push-Location $mediaBuildRoot
try {
    & (Join-Path $mediaBuildRoot "gradlew.bat") :lib-decoder-ffmpeg:assembleRelease
    if ($LASTEXITCODE -ne 0) { throw "AAR build failed" }
} finally {
    Pop-Location
}

$aarPath = Join-Path $mediaBuildRoot "libraries\decoder_ffmpeg\buildout\outputs\aar\lib-decoder-ffmpeg-release.aar"
if (-not (Test-Path -LiteralPath $aarPath)) { throw "Built decoder AAR was not found: $aarPath" }
$aarOutput = Join-Path $outputDir "media3-ffmpeg-decoder-latest-SNAPSHOT.aar"
Copy-Item -LiteralPath $aarPath -Destination $aarOutput -Force
Reset-BuildSubmodulesAfterSuccess
Write-Host "Built AAR: $aarOutput"
