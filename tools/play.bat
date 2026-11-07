@echo off
rem Start Super Tenet: builds it first if the code changed since the last build.
rem Just double-click this file.
setlocal
cd /d "%~dp0.."
tools\bin\onegun-build-windows-amd64.exe play %*
if errorlevel 1 pause
