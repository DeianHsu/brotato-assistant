@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1" %*
set "POTATO_UNINSTALL_EXIT=%ERRORLEVEL%"
if not defined POTATO_AUTOBUILD_NO_PAUSE pause
exit /b %POTATO_UNINSTALL_EXIT%
