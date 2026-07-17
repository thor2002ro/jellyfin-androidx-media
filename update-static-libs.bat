@echo off
setlocal

set "MEDIA_VERSION_ARG="
set "PS_ARGS="

if "%~1"=="" goto collect_args
set "FIRST_ARG=%~1"
call set "FIRST_CHAR=%%FIRST_ARG:~0,1%%"
if "%FIRST_CHAR%"=="-" goto collect_args
set "MEDIA_VERSION_ARG=%~1"
shift /1

:collect_args
if "%~1"=="" goto run_script
set PS_ARGS=%PS_ARGS% "%~1"
shift /1
goto collect_args

:run_script
if defined MEDIA_VERSION_ARG (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-static-libs.ps1" -MediaVersion "%MEDIA_VERSION_ARG%" %PS_ARGS%
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-static-libs.ps1" %PS_ARGS%
)
exit /b %ERRORLEVEL%
