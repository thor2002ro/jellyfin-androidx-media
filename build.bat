@echo off
setlocal

set "TEMP=%SystemDrive%\tmp"
set "TMP=%TEMP%"

if not exist "%TEMP%\" (
    mkdir "%TEMP%" || exit /b 1
)

call "%~dp0update-repo.bat" %*
exit /b %ERRORLEVEL%
