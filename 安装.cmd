@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" %*
set "POTATO_INSTALL_EXIT=%ERRORLEVEL%"
if not defined POTATO_AUTOBUILD_NO_PAUSE pause
exit /b %POTATO_INSTALL_EXIT%
