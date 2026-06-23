@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-static-libs.ps1" %*
exit /b %ERRORLEVEL%
