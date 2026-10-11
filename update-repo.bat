@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "REPO_ROOT=%~dp0"
set "JNI_FFMPEG=%REPO_ROOT%media\libraries\decoder_ffmpeg\src\main\jni\ffmpeg"
set "AAR_OUTPUT=%OUTPUT_DIR%"
set "WINDOWS_PREPARE_ONLY="
set "PREPARE_PROGRESS=[1/3]"
set "RESULT_EXIT=0"
set "CLEANUP_EXIT=0"

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
    echo.
    echo Error: Source preparation failed with exit code %PREPARE_EXIT%.
    echo The build did not start because update-repo.sh returned an error.
    set "RESULT_EXIT=%PREPARE_EXIT%"
    goto cleanup
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
    echo.
    echo Error: Windows could not create the Media3 FFmpeg directory junction.
    echo Check that the destination is writable and no process is using the old path.
    set "RESULT_EXIT=%JUNCTION_EXIT%"
    goto cleanup
)

echo.
echo [3/3] Building Android archives...
call "%REPO_ROOT%gradlew.bat" ^
    -PffmpegStaticMode=%FFMPEG_STATIC_MODE% ^
    buildMedia3Aars
set "BUILD_EXIT=%ERRORLEVEL%"

if not "%BUILD_EXIT%"=="0" (
    echo.
    echo Build failed. Gradle exited with code %BUILD_EXIT%.
    set "RESULT_EXIT=%BUILD_EXIT%"
    goto cleanup
)

:cleanup
if exist "%JNI_FFMPEG%\" rmdir "%JNI_FFMPEG%" >nul 2>nul
if exist "%JNI_FFMPEG%\" rmdir /s /q "%JNI_FFMPEG%"
if exist "%JNI_FFMPEG%\" (
    echo.
    echo Error: The Media3 FFmpeg junction could not be removed.
    set "CLEANUP_EXIT=1"
    goto finish
)
"%BASH_EXE%" --noprofile --norc "./update-repo.sh" --restore-only
set "RESTORE_EXIT=%ERRORLEVEL%"
if not "%RESTORE_EXIT%"=="0" (
    echo.
    echo Error: Restoring submodules failed with exit code %RESTORE_EXIT%.
    set "CLEANUP_EXIT=%RESTORE_EXIT%"
)

:finish
if "%RESULT_EXIT%"=="0" if not "%CLEANUP_EXIT%"=="0" set "RESULT_EXIT=%CLEANUP_EXIT%"
popd
if not "%RESULT_EXIT%"=="0" exit /b %RESULT_EXIT%
echo.
echo Build complete.
echo Artifacts: "%AAR_OUTPUT%"
exit /b 0
