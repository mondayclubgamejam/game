@echo off
rem Build the game for this OS (or pass -target linux, windows or all).
rem Runs a prebuilt, dependency-free builder from tools\bin (source: tools\builder).
setlocal
rem Run from the project root, one folder up.
cd /d "%~dp0.."
tools\bin\onegun-build-windows-amd64.exe %*
set ERR=%ERRORLEVEL%
rem Keep the window open when double-clicked.
if "%~1"=="" pause
exit /b %ERR%
