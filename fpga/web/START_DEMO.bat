@echo off
REM ===========================================================================
REM START_DEMO.bat -- double-click to open the 7-segment web demo.
REM
REM Starts a small local web server (Web Serial needs http://localhost, not a
REM file opened from disk) and opens the page in Chrome, or Edge if Chrome is
REM missing. Close this window to stop the server.
REM ===========================================================================
cd /d "%~dp0"

set PAGE=seg7_demo.html
if not "%~1"=="" set PAGE=%~1
set URL=http://localhost:8000/%PAGE%

set PY=python
if exist "%LocalAppData%\Programs\Python\Python313\python.exe" set PY="%LocalAppData%\Programs\Python\Python313\python.exe"

set BROWSER=
if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe"   set BROWSER="%LocalAppData%\Google\Chrome\Application\chrome.exe"
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe"   set BROWSER="%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined BROWSER if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set BROWSER="%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"

echo Serving %CD% at http://localhost:8000
echo Opening %URL%
echo Keep this window open while using the page. Close it to stop.
echo.

if defined BROWSER (start "" %BROWSER% "%URL%") else (start "" "%URL%")
%PY% -m http.server 8000 --bind 127.0.0.1
pause
