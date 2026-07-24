@echo off
call "%~dp0update-repo.bat" %*
exit /b %ERRORLEVEL%
