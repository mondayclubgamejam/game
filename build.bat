@echo off
rem Build for this OS (pass --target windows^|linux^|all to choose). See tools\build.py.
setlocal
cd /d "%~dp0"
set PY=
where py >nul 2>nul && set PY=py -3
if not defined PY where python >nul 2>nul && set PY=python
if not defined PY (
  echo Python 3 is needed to build. Install it from https://www.python.org/downloads/ and run this again.
  goto done
)
%PY% tools\build.py %*
:done
rem Keep the window open when double-clicked.
if "%~1"=="" pause
