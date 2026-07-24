@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "REPO_ROOT=%~dp0"
set "JNI_FFMPEG=%REPO_ROOT%media\libraries\decoder_ffmpeg\src\main\jni\ffmpeg"
set "AAR_OUTPUT=%OUTPUT_DIR%"
set "WINDOWS_PREPARE_ONLY="
set "PREPARE_PROGRESS=[1/3]"

if not defined AAR_OUTPUT set "AAR_OUTPUT=%REPO_ROOT%OUTPUT"
if /I "%~1"=="--prepare-only" set "WINDOWS_PREPARE_ONLY=1"
if defined WINDOWS_PREPARE_ONLY set "PREPARE_PROGRESS=[1/1]"

set "SHOW_HELP="
if /I "%~1"=="-h" set "SHOW_HELP=1"
if /I "%~1"=="--help" set "SHOW_HELP=1"
if /I "%~1"=="/?" set "SHOW_HELP=1"
if defined SHOW_HELP (
    echo Usage: update-repo.bat [options] [media-ref] [merge-ref] [ffmpeg-ref]
    echo.
    echo Prepare the patched AndroidX Media checkout and build Jellyfin's Media3 AARs.
    echo.
    echo Options:
    echo   --prepare-only  Update and patch the source trees, then stop.
    echo   --build-only    Reuse source trees prepared by an earlier run.
    echo   -h, --help      Show this help text.
    echo.
    echo Environment:
    echo   FFMPEG_STATIC_MODE=source^|prebuilt
    echo   OUTPUT_DIR, MEDIA_VERSION, MEDIA_MERGE_VERSION, FFMPEG_REF
    exit /b 0
)

echo.
echo Checking the Windows build environment...

set "BASH_EXE="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH_EXE for %%I in (bash.exe) do if not "%%~$PATH:I"=="" set "BASH_EXE=%%~$PATH:I"

if not defined BASH_EXE (
    echo.
    echo Error: Git Bash was not found.
    echo Install Git for Windows, then run the build again.
    exit /b 1
)

if not defined ANDROID_HOME if defined ANDROID_SDK_ROOT set "ANDROID_HOME=%ANDROID_SDK_ROOT%"
if not defined ANDROID_HOME if exist "%LocalAppData%\Android\Sdk\" set "ANDROID_HOME=%LocalAppData%\Android\Sdk"

if not defined FFMPEG_STATIC_MODE set "FFMPEG_STATIC_MODE=source"
if /I not "%FFMPEG_STATIC_MODE%"=="source" if /I not "%FFMPEG_STATIC_MODE%"=="prebuilt" (
    echo.
    echo Error: FFMPEG_STATIC_MODE must be source or prebuilt; got "%FFMPEG_STATIC_MODE%".
    exit /b 1
)

set "FFMPEG_PREPARE_TASK=prepareFfmpegPrebuiltDependencies"
if /I "%FFMPEG_STATIC_MODE%"=="source" (
    set "FFMPEG_PREPARE_TASK=prepareFfmpegSourceDependencies"
    where wsl.exe >nul 2>nul
    if errorlevel 1 (
        echo.
        echo Error: WSL is required to build FFmpeg static libraries from source on Windows.
        echo Set FFMPEG_STATIC_MODE=prebuilt only when complete ABI archives are available.
        exit /b 1
    )

    wsl.exe bash -lc "command -v make >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && command -v tr >/dev/null 2>&1 && command -v mktemp >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1"
    if errorlevel 1 (
        echo.
        echo Error: The default WSL distribution is missing a required build tool.
        echo Install GNU make, Git, tar, tr, mktemp, and wslpath inside WSL.
        exit /b 1
    )
)

rem Remove a junction from an earlier build before Git Bash cleans Media3.
if exist "%JNI_FFMPEG%\" rmdir "%JNI_FFMPEG%" >nul 2>nul
if exist "%JNI_FFMPEG%\" rmdir /s /q "%JNI_FFMPEG%"
if exist "%JNI_FFMPEG%\" (
    echo.
    echo Error: Could not remove the existing Media3 FFmpeg path:
    echo   "%JNI_FFMPEG%"
    echo Close processes using that directory, then run the build again.
    exit /b 1
)

echo.
echo %PREPARE_PROGRESS% Preparing source trees...
pushd "%REPO_ROOT%"
if errorlevel 1 (
    echo.
    echo Error: Could not enter the repository directory:
    echo   "%REPO_ROOT%"
    exit /b 1
)

"%BASH_EXE%" --noprofile --norc "./update-repo.sh" --prepare-only %*
set "PREPARE_EXIT=%ERRORLEVEL%"
if not "%PREPARE_EXIT%"=="0" (
    popd
    echo.
    echo Error: Source preparation failed with exit code %PREPARE_EXIT%.
    echo The build did not start because update-repo.sh returned an error.
    exit /b %PREPARE_EXIT%
)

if defined WINDOWS_PREPARE_ONLY (
    popd
    echo.
    echo Source preparation is complete.
    exit /b 0
)

echo.
echo [2/3] Connecting FFmpeg to Media3...
if exist "%JNI_FFMPEG%\" rmdir "%JNI_FFMPEG%" >nul 2>nul
if exist "%JNI_FFMPEG%\" rmdir /s /q "%JNI_FFMPEG%"
mklink /J "%JNI_FFMPEG%" "%REPO_ROOT%ffmpeg" >nul
set "JUNCTION_EXIT=%ERRORLEVEL%"
if not "%JUNCTION_EXIT%"=="0" (
    popd
    echo.
    echo Error: Windows could not create the Media3 FFmpeg directory junction.
    echo Check that the destination is writable and no process is using the old path.
    exit /b %JUNCTION_EXIT%
)

echo.
echo [3/3] Building Android archives...
call "%REPO_ROOT%gradlew.bat" ^
    -PffmpegStaticMode=%FFMPEG_STATIC_MODE% ^
    %FFMPEG_PREPARE_TASK% ^
    buildMedia3Aars
set "BUILD_EXIT=%ERRORLEVEL%"

if not "%BUILD_EXIT%"=="0" (
    popd
    echo.
    echo Build failed. Gradle exited with code %BUILD_EXIT%.
    exit /b %BUILD_EXIT%
)

if exist "%JNI_FFMPEG%\" rmdir "%JNI_FFMPEG%" >nul 2>nul
if exist "%JNI_FFMPEG%\" rmdir /s /q "%JNI_FFMPEG%"
if exist "%JNI_FFMPEG%\" (
    popd
    echo.
    echo Error: Build succeeded, but the Media3 FFmpeg junction could not be removed.
    exit /b 1
)
"%BASH_EXE%" --noprofile --norc "./update-repo.sh" --restore-only
set "RESTORE_EXIT=%ERRORLEVEL%"
if not "%RESTORE_EXIT%"=="0" (
    popd
    echo.
    echo Error: Build succeeded, but restoring submodules failed with exit code %RESTORE_EXIT%.
    exit /b %RESTORE_EXIT%
)

popd
echo.
echo Build complete.
echo Artifacts: "%AAR_OUTPUT%"
exit /b 0
